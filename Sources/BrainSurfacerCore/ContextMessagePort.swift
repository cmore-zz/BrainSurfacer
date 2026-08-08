import CoreFoundation
import Foundation

/// A per-process, local IPC endpoint for editor-context replacement snapshots.
///
/// The endpoint name includes the target process identifier so connectors can
/// address the exact installed or development build that they discovered.
/// Delivery does not ask Launch Services to open or reorder the application.
public enum ContextMessagePortEndpoint {
    public static let applicationGroup = "group.org.brainsurfacer.BrainSurfacer"
    public static let updateMessageID: Int32 = 1
    public static let maximumPayloadBytes = EditorContextInput.maximumJSONBytes

    public static func name(processIdentifier: pid_t) -> String {
        "\(applicationGroup).context.\(processIdentifier)"
    }
}

public enum ContextMessagePortError: LocalizedError, Equatable {
    case listenerRegistrationFailed(pid_t)
    case listenerAlreadyExists(pid_t)
    case listenerUnavailable(pid_t)
    case payloadTooLarge
    case sendTimedOut
    case replyTimedOut
    case listenerInvalid
    case transportFailed
    case updateRejected

    public var errorDescription: String? {
        switch self {
        case let .listenerRegistrationFailed(processIdentifier):
            "BrainSurfacer process \(processIdentifier) couldn’t register its context listener."
        case let .listenerAlreadyExists(processIdentifier):
            "BrainSurfacer process \(processIdentifier) already has a context listener."
        case let .listenerUnavailable(processIdentifier):
            "BrainSurfacer process \(processIdentifier) is not accepting context updates."
        case .payloadTooLarge:
            "The editor-context snapshot is too large for local delivery."
        case .sendTimedOut:
            "Sending editor context to BrainSurfacer timed out."
        case .replyTimedOut:
            "BrainSurfacer did not acknowledge the editor-context update in time."
        case .listenerInvalid:
            "BrainSurfacer stopped accepting editor-context updates."
        case .transportFailed:
            "The local editor-context transport failed."
        case .updateRejected:
            "BrainSurfacer rejected the editor-context update."
        }
    }
}

/// Listens for context updates on a serial background queue.
///
/// A valid update is acknowledged after decoding and then handed to the main
/// actor. Enrollment and expiration policy remain the responsibility of the
/// application's existing ingestion path.
public final class ContextMessagePortServer: @unchecked Sendable {
    public typealias Handler = @MainActor @Sendable (EditorContextUpdate) async -> Void

    fileprivate static let acceptedReply = Data([1])
    private let handlerBox: HandlerBox
    private let port: CFMessagePort
    private let queue: DispatchQueue

    public init(
        processIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        handler: @escaping Handler
    ) throws {
        let handlerBox = HandlerBox(handler: handler)
        var context = CFMessagePortContext(
            version: 0,
            info: Unmanaged.passUnretained(handlerBox).toOpaque(),
            retain: { information in
                guard let information else {
                    return nil
                }
                let retained = Unmanaged<HandlerBox>
                    .fromOpaque(information)
                    .retain()
                return UnsafeRawPointer(retained.toOpaque())
            },
            release: { information in
                guard let information else {
                    return
                }
                Unmanaged<HandlerBox>
                    .fromOpaque(information)
                    .release()
            },
            copyDescription: nil
        )
        var shouldFreeInfo = DarwinBoolean(false)
        let name = ContextMessagePortEndpoint.name(
            processIdentifier: processIdentifier
        ) as CFString
        guard let port = CFMessagePortCreateLocal(
            nil,
            name,
            Self.receive,
            &context,
            &shouldFreeInfo
        ) else {
            throw ContextMessagePortError.listenerRegistrationFailed(
                processIdentifier
            )
        }
        guard !shouldFreeInfo.boolValue else {
            throw ContextMessagePortError.listenerAlreadyExists(processIdentifier)
        }

        self.handlerBox = handlerBox
        self.port = port
        queue = DispatchQueue(
            label: "org.brainsurfacer.BrainSurfacer.context-listener"
        )
        CFMessagePortSetDispatchQueue(port, queue)
    }

    deinit {
        CFMessagePortSetDispatchQueue(port, nil)
        CFMessagePortInvalidate(port)
    }

    private static let receive: CFMessagePortCallBack = {
        _, messageID, data, information in
        guard messageID == ContextMessagePortEndpoint.updateMessageID,
              let data,
              CFDataGetLength(data) <= ContextMessagePortEndpoint.maximumPayloadBytes,
              let information,
              let update = try? JSONDecoder().decode(
                  EditorContextUpdate.self,
                  from: data as Data
              ) else {
            return nil
        }

        let handlerBox = Unmanaged<HandlerBox>
            .fromOpaque(information)
            .takeUnretainedValue()
        Task {
            await handlerBox.handler(update)
        }
        return Unmanaged.passRetained(acceptedReply as CFData)
    }

    private final class HandlerBox: @unchecked Sendable {
        let handler: Handler

        init(handler: @escaping Handler) {
            self.handler = handler
        }
    }
}

/// Sends one validated replacement snapshot to an already-running process.
public struct ContextMessagePortClient: Sendable {
    public var sendTimeout: TimeInterval
    public var replyTimeout: TimeInterval

    public init(
        sendTimeout: TimeInterval = 1,
        replyTimeout: TimeInterval = 1
    ) {
        self.sendTimeout = sendTimeout
        self.replyTimeout = replyTimeout
    }

    public func send(
        _ update: EditorContextUpdate,
        to processIdentifier: pid_t
    ) throws {
        let payload = try JSONEncoder().encode(update)
        guard payload.count <= ContextMessagePortEndpoint.maximumPayloadBytes else {
            throw ContextMessagePortError.payloadTooLarge
        }

        let name = ContextMessagePortEndpoint.name(
            processIdentifier: processIdentifier
        ) as CFString
        guard let port = CFMessagePortCreateRemote(nil, name) else {
            throw ContextMessagePortError.listenerUnavailable(processIdentifier)
        }

        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(
            port,
            ContextMessagePortEndpoint.updateMessageID,
            payload as CFData,
            sendTimeout,
            replyTimeout,
            CFRunLoopMode.defaultMode.rawValue,
            &reply
        )
        try Self.validate(status: status)
        guard let reply = reply?.takeRetainedValue(),
              reply as Data == ContextMessagePortServer.acceptedReply else {
            throw ContextMessagePortError.updateRejected
        }
    }

    private static func validate(status: Int32) throws {
        switch status {
        case kCFMessagePortSuccess:
            return
        case kCFMessagePortSendTimeout:
            throw ContextMessagePortError.sendTimedOut
        case kCFMessagePortReceiveTimeout:
            throw ContextMessagePortError.replyTimedOut
        case kCFMessagePortIsInvalid, kCFMessagePortBecameInvalidError:
            throw ContextMessagePortError.listenerInvalid
        default:
            throw ContextMessagePortError.transportFailed
        }
    }
}

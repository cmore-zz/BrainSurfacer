import CoreServices
import Foundation

public enum SourceChangeObservationError: LocalizedError {
    case noSourceDirectories
    case streamCreationFailed
    case streamStartFailed

    public var errorDescription: String? {
        switch self {
        case .noSourceDirectories:
            "No source directories were provided for observation."
        case .streamCreationFailed:
            "macOS could not create a filesystem event stream."
        case .streamStartFailed:
            "macOS could not start the filesystem event stream."
        }
    }
}

/// A running FSEvents stream. The caller owns this object and should cancel it
/// before replacing the set of observed roots.
public final class SourceChangeSubscription: @unchecked Sendable {
    public let events: AsyncStream<Set<URL>>

    private let callbackState: FSEventsCallbackState
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var accessedSourceURLs: [URL]
    private var isCancelled = false
    private var stream: FSEventStreamRef?

    fileprivate init(sourceURLs: [URL], latency: TimeInterval) throws {
        let pair = AsyncStream<Set<URL>>.makeStream()
        events = pair.stream
        callbackState = FSEventsCallbackState(
            sourceURLs: sourceURLs,
            continuation: pair.continuation
        )
        queue = DispatchQueue(
            label: "com.brainsurfacer.source-events.\(UUID().uuidString)"
        )
        accessedSourceURLs = sourceURLs.filter {
            $0.startAccessingSecurityScopedResource()
        }
        stream = nil

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackState).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = sourceURLs.map(\.path) as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagIgnoreSelf
        )

        guard let createdStream = FSEventStreamCreate(
            nil,
            sourceEventCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            pair.continuation.finish()
            stopAccessingSourceURLs()
            throw SourceChangeObservationError.streamCreationFailed
        }
        stream = createdStream
        FSEventStreamSetDispatchQueue(createdStream, queue)

        guard FSEventStreamStart(createdStream) else {
            stream = nil
            FSEventStreamInvalidate(createdStream)
            FSEventStreamRelease(createdStream)
            pair.continuation.finish()
            stopAccessingSourceURLs()
            throw SourceChangeObservationError.streamStartFailed
        }
    }

    deinit {
        cancel()
    }

    public func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        let runningStream = stream
        stream = nil
        lock.unlock()

        if let runningStream {
            FSEventStreamStop(runningStream)
            FSEventStreamInvalidate(runningStream)
            FSEventStreamRelease(runningStream)
        }
        callbackState.finish()
        stopAccessingSourceURLs()
    }

    private func stopAccessingSourceURLs() {
        let sourceURLs = accessedSourceURLs
        accessedSourceURLs.removeAll()
        for sourceURL in sourceURLs {
            sourceURL.stopAccessingSecurityScopedResource()
        }
    }
}

/// Observes enrolled source roots using the macOS FSEvents service.
public struct FSEventsSourceObserver: Sendable {
    private let latency: TimeInterval

    public init(latency: TimeInterval = 0.25) {
        self.latency = latency
    }

    public func observe(_ sources: [SourceDirectory]) throws -> SourceChangeSubscription {
        let sourceURLs = Array(
            Set(sources.map { $0.url.standardizedFileURL })
        ).sorted { $0.path < $1.path }
        guard !sourceURLs.isEmpty else {
            throw SourceChangeObservationError.noSourceDirectories
        }
        return try SourceChangeSubscription(
            sourceURLs: sourceURLs,
            latency: latency
        )
    }

    static func affectedSourceURLs(
        for eventURLs: [URL],
        among sourceURLs: [URL]
    ) -> Set<URL> {
        let standardizedSources = sourceURLs.map(\.standardizedFileURL)
        return Set(standardizedSources.filter { sourceURL in
            eventURLs.contains { eventURL in
                eventURL.standardizedFileURL.isDescendant(of: sourceURL)
            }
        })
    }
}

private final class FSEventsCallbackState: @unchecked Sendable {
    private let sourceURLs: [URL]
    private let continuation: AsyncStream<Set<URL>>.Continuation

    init(
        sourceURLs: [URL],
        continuation: AsyncStream<Set<URL>>.Continuation
    ) {
        self.sourceURLs = sourceURLs
        self.continuation = continuation
    }

    func receive(
        eventCount: Int,
        eventPaths: UnsafeMutableRawPointer,
        eventFlags: UnsafePointer<FSEventStreamEventFlags>
    ) {
        let resetFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagEventIdsWrapped
        )
        let paths = eventPaths.assumingMemoryBound(
            to: UnsafePointer<CChar>?.self
        )
        var eventURLs: [URL] = []
        eventURLs.reserveCapacity(eventCount)

        for index in 0..<eventCount {
            if eventFlags[index] & resetFlags != 0 {
                continuation.yield(Set(sourceURLs))
                return
            }
            if let path = paths[index] {
                eventURLs.append(URL(fileURLWithPath: String(cString: path)))
            }
        }

        let affectedURLs = FSEventsSourceObserver.affectedSourceURLs(
            for: eventURLs,
            among: sourceURLs
        )
        if !affectedURLs.isEmpty {
            continuation.yield(affectedURLs)
        }
    }

    func finish() {
        continuation.finish()
    }
}

private let sourceEventCallback: FSEventStreamCallback = {
    _, info, eventCount, eventPaths, eventFlags, _ in
    guard let info else {
        return
    }
    let state = Unmanaged<FSEventsCallbackState>
        .fromOpaque(info)
        .takeUnretainedValue()
    state.receive(
        eventCount: eventCount,
        eventPaths: eventPaths,
        eventFlags: eventFlags
    )
}

private extension URL {
    func isDescendant(of directoryURL: URL) -> Bool {
        let directoryComponents = directoryURL.pathComponents
        let candidateComponents = pathComponents
        guard candidateComponents.count >= directoryComponents.count else {
            return false
        }
        return candidateComponents.prefix(directoryComponents.count)
            .elementsEqual(directoryComponents)
    }
}

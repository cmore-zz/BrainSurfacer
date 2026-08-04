import BrainSurfacerModel
import Foundation

public struct EditorContextDocument: Codable, Equatable, Sendable {
    public var anchor: SourceAnchor
    public var relevance: ContextRelevance

    public init(
        anchor: SourceAnchor,
        relevance: ContextRelevance
    ) {
        self.anchor = anchor
        self.relevance = relevance
    }

    public init(
        fileURL: URL,
        relevance: ContextRelevance
    ) {
        self.init(
            anchor: SourceAnchor(fileURL: fileURL),
            relevance: relevance
        )
    }
}

/// A bounded, replaceable snapshot sent by a local editor connector.
///
/// The transport deliberately carries source anchors rather than document
/// contents. Receivers must still enforce source enrollment before ingestion.
public struct EditorContextUpdate: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let defaultTimeToLive: TimeInterval = 60
    public static let maximumTimeToLive: TimeInterval = 300
    public static let maximumDocumentCount = 100
    public static let maximumPathBytes = 16_384

    public enum Error: LocalizedError, Equatable {
        case unsupportedVersion(Int)
        case invalidProviderID
        case invalidTimeToLive
        case tooManyDocuments
        case invalidDocumentURL
        case payloadTooLarge
        case stale
        case observedInFuture

        public var errorDescription: String? {
            switch self {
            case let .unsupportedVersion(version):
                "Unsupported editor-context version \(version)."
            case .invalidProviderID:
                "The editor-context provider identifier is invalid."
            case .invalidTimeToLive:
                "The editor-context expiration is invalid."
            case .tooManyDocuments:
                "The editor-context snapshot contains too many documents."
            case .invalidDocumentURL:
                "Editor context may reference only local file URLs."
            case .payloadTooLarge:
                "The editor-context snapshot is too large."
            case .stale:
                "The editor-context snapshot has expired."
            case .observedInFuture:
                "The editor-context timestamp is too far in the future."
            }
        }
    }

    public var version: Int
    public var providerID: String
    public var observedAt: Date
    public var timeToLive: TimeInterval
    public var documents: [EditorContextDocument]

    public init(
        providerID: String,
        observedAt: Date = Date(),
        timeToLive: TimeInterval = Self.defaultTimeToLive,
        documents: [EditorContextDocument]
    ) throws {
        version = Self.currentVersion
        self.providerID = providerID
        self.observedAt = observedAt
        self.timeToLive = timeToLive
        self.documents = documents
        try validateShape()
    }

    public func contextSnapshot(receivedAt: Date = Date()) throws -> ContextSnapshot {
        try validateShape()
        guard observedAt <= receivedAt.addingTimeInterval(30) else {
            throw Error.observedInFuture
        }
        let expiresAt = observedAt.addingTimeInterval(timeToLive)
        guard expiresAt > receivedAt else {
            throw Error.stale
        }
        return ContextSnapshot(
            providerID: providerID,
            observedAt: observedAt,
            contributions: documents.map {
                ContextContribution(
                    reference: .sourceAnchor($0.anchor),
                    relevance: $0.relevance,
                    expiresAt: expiresAt
                )
            }
        )
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        providerID = try values.decode(String.self, forKey: .providerID)
        observedAt = try values.decode(Date.self, forKey: .observedAt)
        timeToLive = try values.decode(TimeInterval.self, forKey: .timeToLive)
        documents = try values.decode(
            [EditorContextDocument].self,
            forKey: .documents
        )
        try validateShape()
    }

    private func validateShape() throws {
        guard version == Self.currentVersion else {
            throw Error.unsupportedVersion(version)
        }
        let provider = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider == providerID,
              !provider.isEmpty,
              provider.utf8.count <= 128,
              provider.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw Error.invalidProviderID
        }
        guard timeToLive.isFinite,
              timeToLive > 0,
              timeToLive <= Self.maximumTimeToLive else {
            throw Error.invalidTimeToLive
        }
        guard documents.count <= Self.maximumDocumentCount else {
            throw Error.tooManyDocuments
        }
        guard documents.allSatisfy({ $0.anchor.fileURL.isFileURL }) else {
            throw Error.invalidDocumentURL
        }
        let pathBytes = documents.reduce(into: 0) {
            $0 += $1.anchor.fileURL.path(percentEncoded: false).utf8.count
        }
        guard pathBytes <= Self.maximumPathBytes else {
            throw Error.payloadTooLarge
        }
    }
}

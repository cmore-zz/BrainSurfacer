import AppIntents
import BrainSurfacerCore
import BrainSurfacerModel
@preconcurrency import CoreSpotlight
import CryptoKit
import Foundation
import UniformTypeIdentifiers

public struct SpotlightKnowledgeEntity: IndexedEntity {
    public static let searchDomainIdentifier = "SpotlightKnowledgeEntity"

    private static let maximumCanonicalIdentifierLength = 2_048

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Knowledge Item"
    }

    public static let defaultQuery = Query()

    public var id: String
    public var title: String
    public var subtitle: String
    public var text: String?
    public var tags: [String]
    public var sourceURL: URL
    public var modifiedAt: Date?

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    public var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = title
        attributes.displayName = title
        attributes.contentDescription = text
        attributes.textContent = text
        attributes.keywords = tags
        attributes.contentURL = sourceURL
        attributes.contentModificationDate = modifiedAt
        return attributes
    }

    public init(_ entity: KnowledgeEntity) {
        id = Self.indexIdentifier(for: entity.id)
        title = entity.title
        subtitle = entity.kind.rawValue.capitalized
        text = entity.summary ?? entity.body
        tags = entity.tags.sorted()
        sourceURL = entity.source.fileURL
        modifiedAt = entity.modifiedAt
    }

    static func indexIdentifier(for entityID: EntityID) -> String {
        let canonicalIdentifier = entityID.rawValue
        guard canonicalIdentifier.utf8.count > maximumCanonicalIdentifierLength else {
            return canonicalIdentifier
        }

        let digest = SHA256.hash(data: Data(canonicalIdentifier.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:\(digest)"
    }

    public struct Query: EntityQuery {
        public init() {}

        public func entities(for identifiers: [String]) async throws -> [SpotlightKnowledgeEntity] {
            []
        }
    }
}

public struct SpotlightIndexingError: LocalizedError, Sendable {
    public let code: Int

    public init(code: Int) {
        self.code = code
    }

    public var errorDescription: String? {
        switch code {
        case -1000:
            "Spotlight’s index is temporarily unavailable. Try reindexing."
        case -1001:
            "Spotlight rejected an entity because its metadata was invalid (Core Spotlight -1001)."
        case -1004:
            "BrainSurfacer has exceeded its current Spotlight indexing quota."
        case -1005:
            "Spotlight indexing isn’t supported on this Mac."
        default:
            "Spotlight indexing failed (Core Spotlight \(code))."
        }
    }
}

public actor SpotlightEntityIndex: PermanentEntityIndex {
    public static let indexName = "BrainSurfacerKnowledge"

    private let index: CSSearchableIndex

    public init(index: CSSearchableIndex = CSSearchableIndex(name: indexName)) {
        self.index = index
    }

    public func apply(_ change: EntityIndexChange) async throws {
        do {
            if !change.upserts.isEmpty {
                try await index.indexAppEntities(change.upserts.map(SpotlightKnowledgeEntity.init))
            }
            if !change.removals.isEmpty {
                try await index.deleteAppEntities(
                    identifiedBy: change.removals.map(SpotlightKnowledgeEntity.indexIdentifier),
                    ofType: SpotlightKnowledgeEntity.self
                )
            }
        } catch {
            let cocoaError = error as NSError
            guard cocoaError.domain == CSIndexErrorDomain else {
                throw error
            }
            throw SpotlightIndexingError(code: cocoaError.code)
        }
    }
}

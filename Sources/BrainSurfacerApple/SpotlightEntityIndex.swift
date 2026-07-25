import AppIntents
import BrainSurfacerCore
import BrainSurfacerModel
@preconcurrency import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

public struct SpotlightKnowledgeEntity: IndexedEntity {
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
        attributes.keywords = tags
        attributes.contentURL = sourceURL
        attributes.contentModificationDate = modifiedAt
        return attributes
    }

    public init(_ entity: KnowledgeEntity) {
        id = entity.id.rawValue
        title = entity.title
        subtitle = entity.kind.rawValue.capitalized
        text = entity.summary ?? entity.body
        tags = entity.tags.sorted()
        sourceURL = entity.source.fileURL
        modifiedAt = entity.modifiedAt
    }

    public struct Query: EntityQuery {
        public init() {}

        public func entities(for identifiers: [String]) async throws -> [SpotlightKnowledgeEntity] {
            []
        }
    }
}

public actor SpotlightEntityIndex: PermanentEntityIndex {
    private let index: CSSearchableIndex

    public init(index: CSSearchableIndex = .default()) {
        self.index = index
    }

    public func apply(_ change: EntityIndexChange) async throws {
        if !change.upserts.isEmpty {
            try await index.indexAppEntities(change.upserts.map(SpotlightKnowledgeEntity.init))
        }
        if !change.removals.isEmpty {
            try await index.deleteAppEntities(
                identifiedBy: change.removals.map(\.rawValue),
                ofType: SpotlightKnowledgeEntity.self
            )
        }
    }
}

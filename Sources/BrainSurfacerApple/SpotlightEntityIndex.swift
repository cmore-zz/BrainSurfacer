import AppIntents
import BrainSurfacerCore
import BrainSurfacerModel
@preconcurrency import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

public struct SpotlightKnowledgeEntity: IndexedEntity {
    public static let searchDomainIdentifier = "SpotlightKnowledgeEntity"

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Knowledge Item"
    }

    public static let defaultQuery = Query()

    public var id: String
    @Property(indexingKey: \.displayName) public var title: String
    @Property public var subtitle: String
    @Property(indexingKey: \.textContent) public var text: String?
    @Property public var summary: String?
    @Property(indexingKey: \.keywords) public var tags: [String]
    @Property(indexingKey: \.contentURL) public var sourceURL: URL
    @Property(indexingKey: \.contentModificationDate) public var modifiedAt: Date?

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    public var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.contentType = UTType.content.identifier
        attributes.displayName = title
        attributes.contentDescription = summary
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
        text = entity.body ?? entity.summary
        summary = entity.summary
        tags = entity.tags.sorted()
        sourceURL = entity.source.fileURL
        modifiedAt = entity.modifiedAt
    }

    static func indexIdentifier(for entityID: EntityID) -> String {
        SpotlightProjection.indexIdentifier(for: entityID)
    }

    public struct Query: IndexedEntityQuery {
        public static let persistentIdentifier = "brainsurfacer.query.custom-knowledge.v1"

        private let catalog: any EntityCatalog

        public init() {
            catalog = PersistentEntityCatalog(
                storageURL: PersistentEntityCatalog.defaultStorageURL(),
                accessMode: .readOnly
            )
        }

        public init(catalog: any EntityCatalog) {
            self.catalog = catalog
        }

        public func entities(for identifiers: [String]) async throws -> [SpotlightKnowledgeEntity] {
            let projections = try await catalog.allEntities()
                .filter { SpotlightProjection.kind(for: $0) == .custom }
                .map(SpotlightKnowledgeEntity.init)
            var projectionByID: [String: SpotlightKnowledgeEntity] = [:]
            for projection in projections {
                projectionByID[projection.id] = projection
            }
            return identifiers.compactMap { projectionByID[$0] }
        }

        public func reindexEntities(
            for identifiers: [String],
            indexDescription: CSSearchableIndexDescription
        ) async throws {
            let index = Self.index(for: indexDescription)
            let entities = try await entities(for: identifiers)
            let foundIdentifiers = Set(entities.map(\.id))
            let missingIdentifiers = identifiers.filter {
                !foundIdentifiers.contains($0)
            }

            if !entities.isEmpty {
                try await index.indexAppEntities(entities)
            }
            if !missingIdentifiers.isEmpty {
                try await index.deleteAppEntities(
                    identifiedBy: missingIdentifiers,
                    ofType: SpotlightKnowledgeEntity.self
                )
            }
        }

        public func reindexAllEntities(
            indexDescription: CSSearchableIndexDescription
        ) async throws {
            let index = Self.index(for: indexDescription)
            try await index.deleteAppEntities(ofType: SpotlightKnowledgeEntity.self)
            let entities = try await catalog.allEntities()
                .filter { SpotlightProjection.kind(for: $0) == .custom }
                .map(SpotlightKnowledgeEntity.init)
            if !entities.isEmpty {
                try await index.indexAppEntities(entities)
            }
        }

        private static func index(
            for description: CSSearchableIndexDescription
        ) -> CSSearchableIndex {
            CSSearchableIndex(
                name: SpotlightEntityIndex.indexName,
                protectionClass: description.protectionClass
            )
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
    private let projectionVersionStore: SpotlightProjectionVersionStore
    private var didPrepareProjection = false

    public init(
        index: CSSearchableIndex = CSSearchableIndex(name: indexName),
        projectionVersionURL: URL? = nil
    ) {
        self.index = index
        projectionVersionStore = SpotlightProjectionVersionStore(
            storageURL: projectionVersionURL
                ?? SpotlightProjectionVersionStore.defaultStorageURL()
        )
    }

    public func apply(_ change: EntityIndexChange) async throws {
        do {
            try await prepareProjectionIfNeeded()

            let projectedUpsertIdentifiers = change.upserts.map {
                SpotlightProjection.indexIdentifier(for: $0.id)
            }
            let identifiersToDelete = Set(projectedUpsertIdentifiers).union(
                change.removals.map(SpotlightProjection.indexIdentifier)
            )
            if !identifiersToDelete.isEmpty {
                let identifiers = Array(identifiersToDelete)
                try await index.deleteAppEntities(
                    identifiedBy: identifiers,
                    ofType: SpotlightKnowledgeEntity.self
                )
                try await index.deleteAppEntities(
                    identifiedBy: identifiers,
                    ofType: SpotlightNoteEntity.self
                )
            }

            let notes = change.upserts
                .filter { SpotlightProjection.kind(for: $0) == .note }
                .map(SpotlightNoteEntity.init)
            let customEntities = change.upserts
                .filter { SpotlightProjection.kind(for: $0) == .custom }
                .map(SpotlightKnowledgeEntity.init)
            if !notes.isEmpty {
                try await index.indexAppEntities(notes)
            }
            if !customEntities.isEmpty {
                try await index.indexAppEntities(customEntities)
            }
        } catch {
            let cocoaError = error as NSError
            guard cocoaError.domain == CSIndexErrorDomain else {
                throw error
            }
            throw SpotlightIndexingError(code: cocoaError.code)
        }
    }

    public func reset() async throws {
        do {
            try await index.deleteAppEntities(ofType: SpotlightKnowledgeEntity.self)
            try await index.deleteAppEntities(ofType: SpotlightNoteEntity.self)
            try projectionVersionStore.markCurrent(
                version: SpotlightProjection.schemaVersion
            )
            didPrepareProjection = true
        } catch {
            let cocoaError = error as NSError
            guard cocoaError.domain == CSIndexErrorDomain else {
                throw error
            }
            throw SpotlightIndexingError(code: cocoaError.code)
        }
    }

    private func prepareProjectionIfNeeded() async throws {
        guard !didPrepareProjection else {
            return
        }
        if projectionVersionStore.storedVersion() != SpotlightProjection.schemaVersion {
            try await index.deleteAppEntities(ofType: SpotlightKnowledgeEntity.self)
            try await index.deleteAppEntities(ofType: SpotlightNoteEntity.self)
            try projectionVersionStore.markCurrent(
                version: SpotlightProjection.schemaVersion
            )
        }
        // A version change clears every BrainSurfacer projection. The app's
        // startup path deliberately follows this first apply with reindexAll().
        didPrepareProjection = true
    }
}

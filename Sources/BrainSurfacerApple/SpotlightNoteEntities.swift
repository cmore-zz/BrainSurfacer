import AppIntents
import BrainSurfacerCore
import BrainSurfacerModel
@preconcurrency import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

// Tags, folders, and the source account are relationship values owned by indexed
// notes. They intentionally resolve as AppEntity values without creating their
// own independent Spotlight records.
public struct SpotlightNoteTagEntity: AppEntity {
    public static let defaultQuery = Query()
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Tag"
    }

    public let id: String
    @Property public var name: String

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    public init(name: String) {
        id = SpotlightProjection.tagIdentifier(for: name)
        self.name = name
    }

    public struct Query: EntityQuery {
        public static let persistentIdentifier = "brainsurfacer.query.notes-tag.v1"

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

        public func entities(for identifiers: [String]) async throws -> [SpotlightNoteTagEntity] {
            let requested = Set(identifiers)
            var projectionByID: [String: SpotlightNoteTagEntity] = [:]
            for entity in try await catalog.allEntities() {
                for tag in entity.tags {
                    let projection = SpotlightNoteTagEntity(name: tag)
                    if requested.contains(projection.id) {
                        projectionByID[projection.id] = projection
                    }
                }
            }
            return identifiers.compactMap { projectionByID[$0] }
        }
    }
}

@AppEntity(schema: .notes.account)
public struct SpotlightNoteAccountEntity {
    public static let defaultQuery = Query()

    public let id: String
    public var name: String

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    public init() {
        id = "brainsurfacer-sources"
        name = "BrainSurfacer Sources"
    }

    public struct Query: EntityQuery {
        public static let persistentIdentifier = "brainsurfacer.query.notes-account.v1"

        public init() {}

        public func entities(for identifiers: [String]) async throws -> [SpotlightNoteAccountEntity] {
            let account = SpotlightNoteAccountEntity()
            return identifiers.contains(account.id) ? [account] : []
        }
    }
}

@AppEntity(schema: .notes.folder)
public struct SpotlightNoteFolderEntity {
    public static let defaultQuery = Query()

    public let id: String
    public var name: String
    public var parentFolder: SpotlightNoteFolderEntity? {
        nil
    }
    public var account: SpotlightNoteAccountEntity?

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    public init(directoryURL: URL) {
        let directoryURL = directoryURL.standardizedFileURL
        id = SpotlightProjection.folderIdentifier(for: directoryURL)
        name = directoryURL.lastPathComponent
        account = SpotlightNoteAccountEntity()
    }

    public struct Query: EntityQuery {
        public static let persistentIdentifier = "brainsurfacer.query.notes-folder.v1"

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

        public func entities(for identifiers: [String]) async throws -> [SpotlightNoteFolderEntity] {
            let requested = Set(identifiers)
            var projectionByID: [String: SpotlightNoteFolderEntity] = [:]
            for entity in try await catalog.allEntities() where entity.kind == .note {
                let projection = SpotlightNoteFolderEntity(
                    directoryURL: entity.source.fileURL.deletingLastPathComponent()
                )
                if requested.contains(projection.id) {
                    projectionByID[projection.id] = projection
                }
            }
            return identifiers.compactMap { projectionByID[$0] }
        }
    }
}

@AppEntity(schema: .notes.note)
public struct SpotlightNoteEntity: IndexedEntity {
    public static let searchDomainIdentifier = "SpotlightNoteEntity"
    public static let defaultQuery = Query()

    public let id: String
    private let entity: KnowledgeEntity

    @ComputedProperty public var name: AttributedString {
        AttributedString(entity.title)
    }

    @ComputedProperty public var content: AttributedString? {
        (entity.body ?? entity.summary).map(AttributedString.init)
    }

    @ComputedProperty public var attachments: [IntentFile] {
        []
    }

    @ComputedProperty public var tags: [SpotlightNoteTagEntity] {
        entity.tags.sorted().map(SpotlightNoteTagEntity.init)
    }

    @ComputedProperty public var isPinned: Bool {
        entity.attributes["isPinned"] == "true"
    }

    @ComputedProperty public var creationDate: Date? {
        nil
    }

    @ComputedProperty public var modificationDate: Date? {
        entity.modifiedAt
    }

    @ComputedProperty public var folder: SpotlightNoteFolderEntity? {
        SpotlightNoteFolderEntity(
            directoryURL: entity.source.fileURL.deletingLastPathComponent()
        )
    }

    @ComputedProperty(indexingKey: \.contentURL) public var openURL: URL {
        BrainSurfacerDeepLink.entity(entity.id).url
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(String(name.characters))",
            subtitle: "Note"
        )
    }

    public var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.contentType = UTType.content.identifier
        attributes.contentURL = openURL
        attributes.path = entity.source.fileURL.path
        attributes.textContent = content.map { String($0.characters) }
        attributes.contentDescription = entity.summary
        return attributes
    }

    public init(_ entity: KnowledgeEntity) {
        id = SpotlightProjection.indexIdentifier(for: entity.id)
        self.entity = entity
    }

    var canonicalEntityID: EntityID { entity.id }

    public struct Query: IndexedEntityQuery {
        public static let persistentIdentifier = "brainsurfacer.query.notes-note.v1"

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

        public func entities(for identifiers: [String]) async throws -> [SpotlightNoteEntity] {
            let projections = try await catalog.allEntities()
                .filter { $0.kind == .note }
                .map(SpotlightNoteEntity.init)
            let projectionByID = Dictionary(
                uniqueKeysWithValues: projections.map { ($0.id, $0) }
            )
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
                    ofType: SpotlightNoteEntity.self
                )
            }
        }

        public func reindexAllEntities(
            indexDescription: CSSearchableIndexDescription
        ) async throws {
            let index = Self.index(for: indexDescription)
            try await index.deleteAppEntities(ofType: SpotlightNoteEntity.self)
            let entities = try await catalog.allEntities()
                .filter { $0.kind == .note }
                .map(SpotlightNoteEntity.init)
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

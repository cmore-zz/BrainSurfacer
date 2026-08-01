import BrainSurfacerModel
import Foundation

public actor PersistentEntityCatalog: EntityCatalog {
    public static let currentSchemaVersion = 1

    public let storageURL: URL

    private var entitiesByID: [EntityID: KnowledgeEntity] = [:]
    private var identifiersBySource: [URL: Set<EntityID>] = [:]
    private var providerReferences: [ProviderReference: EntityID] = [:]
    private var pendingChanges: [PendingEntityIndexChange] = []

    public init(storageURL: URL) {
        self.storageURL = storageURL.standardizedFileURL
    }

    public static func defaultStorageURL(
        fileManager: FileManager = .default
    ) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("BrainSurfacer", isDirectory: true)
            .appendingPathComponent("entity-catalog-v1.json", isDirectory: false)
    }

    public func replaceEntities(
        from source: URL,
        with entities: [KnowledgeEntity]
    ) throws -> EntityIndexChange {
        try reload()
        let change = replaceInMemory(from: source, with: entities)
        try persist()
        return change
    }

    public func stageReplacement(
        from source: URL,
        with entities: [KnowledgeEntity]
    ) async throws -> PendingEntityIndexChange {
        try reload()
        let pending = PendingEntityIndexChange(
            change: replaceInMemory(from: source, with: entities)
        )
        pendingChanges.append(pending)
        try persist()
        return pending
    }

    public func pendingIndexChanges() async throws -> [PendingEntityIndexChange] {
        try reload()
        return pendingChanges
    }

    public func acknowledgeIndexChange(identifiedBy identifier: UUID) async throws {
        try reload()
        pendingChanges.removeAll { $0.id == identifier }
        try persist()
    }

    public func entities(
        identifiedBy identifiers: [EntityID]
    ) throws -> [KnowledgeEntity] {
        try reload()
        return identifiers.compactMap { entitiesByID[$0] }
    }

    public func allEntities() throws -> [KnowledgeEntity] {
        try reload()
        return entitiesByID.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public func resolve(_ reference: EntityReference) throws -> KnowledgeEntity? {
        try reload()
        switch reference {
        case let .entityID(identifier):
            return entitiesByID[identifier]

        case let .file(fileURL):
            return candidates(for: fileURL)
                .first(where: { $0.kind == .note })
                ?? candidates(for: fileURL).first

        case let .sourceAnchor(anchor):
            let fileCandidates = candidates(for: anchor.fileURL)

            if let editorIdentifier = anchor.editorIdentifier,
               let match = fileCandidates.first(where: {
                   $0.source.editorIdentifier == editorIdentifier
               }) {
                return match
            }

            if !anchor.headingPath.isEmpty,
               let match = fileCandidates.first(where: {
                   $0.source.headingPath == anchor.headingPath
               }) {
                return match
            }

            if let line = anchor.line,
               let match = fileCandidates.first(where: {
                   $0.source.line == line
               }) {
                return match
            }

            return fileCandidates.first(where: { $0.kind == .note })
                ?? fileCandidates.first

        case let .providerLocal(providerID, value):
            guard let identifier = providerReferences[
                ProviderReference(providerID: providerID, value: value)
            ] else {
                return nil
            }
            return entitiesByID[identifier]
        }
    }

    public func registerProviderReference(
        providerID: String,
        value: String,
        for identifier: EntityID
    ) throws {
        try reload()
        providerReferences[
            ProviderReference(providerID: providerID, value: value)
        ] = identifier
        try persist()
    }

    private func replaceInMemory(
        from source: URL,
        with entities: [KnowledgeEntity]
    ) -> EntityIndexChange {
        let source = source.standardizedFileURL
        let previousSource = EntityIdentityStabilizer.movedSourceCandidate(
            for: source,
            incoming: entities,
            identifiersBySource: identifiersBySource,
            entitiesByID: entitiesByID
        ) ?? source
        let previous = identifiersBySource[previousSource, default: []]
        let previousEntities = previous.compactMap { entitiesByID[$0] }
        let entities = EntityIdentityStabilizer.stabilize(
            entities,
            against: previousEntities
        )
        let next = Set(entities.map(\.id))
        let removals = previous.subtracting(next)

        for identifier in removals {
            entitiesByID.removeValue(forKey: identifier)
        }
        for entity in entities {
            entitiesByID[entity.id] = entity
        }
        if previousSource != source {
            identifiersBySource.removeValue(forKey: previousSource)
        }
        identifiersBySource[source] = next

        return EntityIndexChange(upserts: entities, removals: removals)
    }

    private func candidates(for fileURL: URL) -> [KnowledgeEntity] {
        let standardizedURL = fileURL.standardizedFileURL
        return entitiesByID.values
            .filter { $0.source.fileURL.standardizedFileURL == standardizedURL }
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private func reload() throws {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            entitiesByID = [:]
            identifiersBySource = [:]
            providerReferences = [:]
            pendingChanges = []
            return
        }

        let data = try Data(contentsOf: storageURL)
        let state = try JSONDecoder().decode(PersistedState.self, from: data)
        guard state.schemaVersion == Self.currentSchemaVersion else {
            throw Error.unsupportedSchemaVersion(state.schemaVersion)
        }

        entitiesByID = Dictionary(
            uniqueKeysWithValues: state.entities.map { ($0.id, $0) }
        )
        identifiersBySource = Dictionary(
            uniqueKeysWithValues: state.sources.map {
                ($0.url.standardizedFileURL, Set($0.identifiers))
            }
        )
        providerReferences = Dictionary(
            uniqueKeysWithValues: state.providerReferences.map {
                (
                    ProviderReference(providerID: $0.providerID, value: $0.value),
                    $0.identifier
                )
            }
        )
        pendingChanges = state.pendingChanges
    }

    private func persist() throws {
        let state = PersistedState(
            schemaVersion: Self.currentSchemaVersion,
            entities: entitiesByID.values.sorted { $0.id.rawValue < $1.id.rawValue },
            sources: identifiersBySource.map {
                SourceRecord(
                    url: $0.key,
                    identifiers: $0.value.sorted { $0.rawValue < $1.rawValue }
                )
            }.sorted { $0.url.path < $1.url.path },
            providerReferences: providerReferences.map {
                ProviderReferenceRecord(
                    providerID: $0.key.providerID,
                    value: $0.key.value,
                    identifier: $0.value
                )
            }.sorted {
                if $0.providerID != $1.providerID {
                    return $0.providerID < $1.providerID
                }
                return $0.value < $1.value
            },
            pendingChanges: pendingChanges
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: storageURL, options: [.atomic])
    }
}

public extension PersistentEntityCatalog {
    enum Error: LocalizedError, Equatable {
        case unsupportedSchemaVersion(Int)

        public var errorDescription: String? {
            switch self {
            case let .unsupportedSchemaVersion(version):
                "The entity catalog uses unsupported schema version \(version)."
            }
        }
    }
}

private extension PersistentEntityCatalog {
    struct ProviderReference: Hashable {
        var providerID: String
        var value: String
    }

    struct PersistedState: Codable {
        var schemaVersion: Int
        var entities: [KnowledgeEntity]
        var sources: [SourceRecord]
        var providerReferences: [ProviderReferenceRecord]
        var pendingChanges: [PendingEntityIndexChange]
    }

    struct SourceRecord: Codable {
        var url: URL
        var identifiers: [EntityID]
    }

    struct ProviderReferenceRecord: Codable {
        var providerID: String
        var value: String
        var identifier: EntityID
    }
}

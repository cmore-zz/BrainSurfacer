import BrainSurfacerModel
import Foundation

public actor PersistentEntityCatalog: EntityCatalog {
    public static let currentSchemaVersion = 2

    public enum AccessMode: Sendable, Equatable {
        case readOnly
        case coordinatingWriter
    }

    public let storageURL: URL
    public let accessMode: AccessMode

    private var entitiesByID: [EntityID: KnowledgeEntity] = [:]
    private var identifiersBySource: [URL: Set<EntityID>] = [:]
    private var projectedIdentifiersBySource: [URL: Set<EntityID>] = [:]
    private var providerReferences: [ProviderReference: EntityID] = [:]
    private var pendingChanges: [PendingEntityIndexChange] = []
    private var fullRebuildRequired = false

    public init(
        storageURL: URL,
        accessMode: AccessMode = .readOnly
    ) {
        self.storageURL = storageURL.standardizedFileURL
        self.accessMode = accessMode
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
        try requireCoordinatingWriter()
        try reload()
        let change = replaceInMemory(
            from: source,
            with: entities,
            includeInPermanentIndex: true
        )
        try persist()
        return change
    }

    public func replaceEntities(
        from source: URL,
        with entities: [KnowledgeEntity],
        includeInPermanentIndex: Bool
    ) async throws -> EntityIndexChange {
        try requireCoordinatingWriter()
        try reload()
        let change = replaceInMemory(
            from: source,
            with: entities,
            includeInPermanentIndex: includeInPermanentIndex
        )
        try persist()
        return change
    }

    public func stageReplacement(
        from source: URL,
        with entities: [KnowledgeEntity]
    ) async throws -> PendingEntityIndexChange {
        try requireCoordinatingWriter()
        try reload()
        let pending = PendingEntityIndexChange(
            change: replaceInMemory(
                from: source,
                with: entities,
                includeInPermanentIndex: true
            )
        )
        pendingChanges.append(pending)
        try persist()
        return pending
    }

    public func stageReplacement(
        from source: URL,
        with entities: [KnowledgeEntity],
        includeInPermanentIndex: Bool
    ) async throws -> PendingEntityIndexChange {
        try requireCoordinatingWriter()
        try reload()
        let pending = PendingEntityIndexChange(
            change: replaceInMemory(
                from: source,
                with: entities,
                includeInPermanentIndex: includeInPermanentIndex
            )
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
        try requireCoordinatingWriter()
        try reload()
        pendingChanges.removeAll { $0.id == identifier }
        try persist()
    }

    public func requiresFullRebuild() async throws -> Bool {
        try reload()
        return fullRebuildRequired
    }

    public func markFullRebuildCompleted() async throws {
        try requireCoordinatingWriter()
        try reload()
        pendingChanges = []
        fullRebuildRequired = false
        try persist()
    }

    public func entities(
        identifiedBy identifiers: [EntityID]
    ) throws -> [KnowledgeEntity] {
        try reload()
        return identifiers.compactMap { entitiesByID[$0] }
    }

    public func entities(from source: URL) async throws -> [KnowledgeEntity] {
        try reload()
        return identifiersBySource[source.standardizedFileURL, default: []]
            .compactMap { entitiesByID[$0] }
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public func allEntities() throws -> [KnowledgeEntity] {
        try reload()
        return entitiesByID.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public func permanentlyIndexedEntities() async throws -> [KnowledgeEntity] {
        try reload()
        let identifiers = projectedIdentifiersBySource.values.reduce(
            into: Set<EntityID>()
        ) {
            $0.formUnion($1)
        }
        return identifiers.compactMap { entitiesByID[$0] }
            .sorted { $0.id.rawValue < $1.id.rawValue }
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
        try requireCoordinatingWriter()
        try reload()
        providerReferences[
            ProviderReference(providerID: providerID, value: value)
        ] = identifier
        try persist()
    }

    private func replaceInMemory(
        from source: URL,
        with entities: [KnowledgeEntity],
        includeInPermanentIndex: Bool
    ) -> EntityIndexChange {
        let source = source.standardizedFileURL
        let previousSource = EntityIdentityStabilizer.movedSourceCandidate(
            for: source,
            incoming: entities,
            identifiersBySource: identifiersBySource,
            entitiesByID: entitiesByID
        ) ?? source
        let previous = identifiersBySource[previousSource, default: []]
        let previousProjected = projectedIdentifiersBySource[
            previousSource,
            default: []
        ]
        let previousEntities = previous.compactMap { entitiesByID[$0] }
        let entities = EntityIdentityStabilizer.stabilize(
            entities,
            against: previousEntities
        )
        let next = Set(entities.map(\.id))
        let removedLocalIdentifiers = previous.subtracting(next)
        let nextProjected = includeInPermanentIndex ? next : []
        let projectionRemovals = previousProjected.subtracting(nextProjected)

        for identifier in removedLocalIdentifiers {
            entitiesByID.removeValue(forKey: identifier)
        }
        for entity in entities {
            entitiesByID[entity.id] = entity
        }
        if previousSource != source {
            identifiersBySource.removeValue(forKey: previousSource)
            projectedIdentifiersBySource.removeValue(forKey: previousSource)
        }
        identifiersBySource[source] = next
        projectedIdentifiersBySource[source] = nextProjected

        return EntityIndexChange(
            upserts: includeInPermanentIndex ? entities : [],
            removals: projectionRemovals
        )
    }

    private func candidates(for fileURL: URL) -> [KnowledgeEntity] {
        let standardizedURL = fileURL.standardizedFileURL
        return entitiesByID.values
            .filter { $0.source.fileURL.standardizedFileURL == standardizedURL }
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private func reload() throws {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            resetInMemory(
                fullRebuildRequired: accessMode == .coordinatingWriter
            )
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: storageURL)
        } catch {
            try handleInvalidCatalog(originalData: nil)
            return
        }
        let state: PersistedState
        do {
            state = try JSONDecoder().decode(PersistedState.self, from: data)
        } catch {
            try handleInvalidCatalog(originalData: data)
            return
        }
        guard state.schemaVersion == Self.currentSchemaVersion else {
            try handleInvalidCatalog(originalData: data)
            return
        }
        load(state)
    }

    private func load(_ state: PersistedState) {
        entitiesByID = Dictionary(
            state.entities.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        identifiersBySource = Dictionary(
            state.sources.map {
                ($0.url.standardizedFileURL, Set($0.identifiers))
            },
            uniquingKeysWith: { previous, latest in previous.union(latest) }
        )
        projectedIdentifiersBySource = Dictionary(
            state.sources.map {
                ($0.url.standardizedFileURL, Set($0.projectedIdentifiers))
            },
            uniquingKeysWith: { previous, latest in previous.union(latest) }
        )
        providerReferences = Dictionary(
            state.providerReferences.map {
                (
                    ProviderReference(providerID: $0.providerID, value: $0.value),
                    $0.identifier
                )
            },
            uniquingKeysWith: { _, latest in latest }
        )
        pendingChanges = state.pendingChanges
        fullRebuildRequired = state.fullRebuildRequired ?? false
    }

    private func handleInvalidCatalog(originalData: Data?) throws {
        resetInMemory(fullRebuildRequired: true)
        guard accessMode == .coordinatingWriter else {
            return
        }

        // Correctness depends on the recovery marker, not the diagnostic copy.
        // Keep the invalid bytes in memory while the atomic persist replaces the
        // catalog, then update one bounded quarantine file best-effort.
        try persist()
        if let originalData {
            try? originalData.write(
                to: storageURL.appendingPathExtension("invalid"),
                options: [.atomic]
            )
        }
    }

    private func resetInMemory(fullRebuildRequired: Bool) {
        entitiesByID = [:]
        identifiersBySource = [:]
        projectedIdentifiersBySource = [:]
        providerReferences = [:]
        pendingChanges = []
        self.fullRebuildRequired = fullRebuildRequired
    }

    private func requireCoordinatingWriter() throws {
        guard accessMode == .coordinatingWriter else {
            throw Error.readOnly
        }
    }

    private func persist() throws {
        let state = PersistedState(
            schemaVersion: Self.currentSchemaVersion,
            entities: entitiesByID.values.sorted { $0.id.rawValue < $1.id.rawValue },
            sources: identifiersBySource.map {
                SourceRecord(
                    url: $0.key,
                    identifiers: $0.value.sorted { $0.rawValue < $1.rawValue },
                    projectedIdentifiers: projectedIdentifiersBySource[
                        $0.key,
                        default: []
                    ].sorted { $0.rawValue < $1.rawValue }
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
            pendingChanges: pendingChanges,
            fullRebuildRequired: fullRebuildRequired
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
        case readOnly

        public var errorDescription: String? {
            switch self {
            case .readOnly:
                "This entity catalog is configured for read-only resolution."
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
        var fullRebuildRequired: Bool?
    }

    struct SourceRecord: Codable {
        var url: URL
        var identifiers: [EntityID]
        var projectedIdentifiers: [EntityID]
    }

    struct ProviderReferenceRecord: Codable {
        var providerID: String
        var value: String
        var identifier: EntityID
    }
}

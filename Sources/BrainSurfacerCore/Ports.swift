import BrainSurfacerModel
import Foundation

public struct EntityIndexChange: Codable, Sendable, Equatable {
    public var upserts: [KnowledgeEntity]
    public var removals: Set<EntityID>

    public init(upserts: [KnowledgeEntity], removals: Set<EntityID>) {
        self.upserts = upserts
        self.removals = removals
    }
}

public struct PendingEntityIndexChange: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var createdAt: Date
    public var change: EntityIndexChange

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        change: EntityIndexChange
    ) {
        self.id = id
        self.createdAt = createdAt
        self.change = change
    }
}

public protocol PermanentEntityIndex: Sendable {
    func apply(_ change: EntityIndexChange) async throws
    func reset() async throws
}

public enum PermanentEntityIndexError: LocalizedError, Sendable, Equatable {
    case fullResetUnsupported

    public var errorDescription: String? {
        switch self {
        case .fullResetUnsupported:
            "This permanent entity index does not support a full reset."
        }
    }
}

public extension PermanentEntityIndex {
    func reset() async throws {
        throw PermanentEntityIndexError.fullResetUnsupported
    }
}

public protocol EntityCatalog: Sendable {
    func replaceEntities(
        from source: URL,
        with entities: [KnowledgeEntity]
    ) async throws -> EntityIndexChange

    func replaceEntities(
        from source: URL,
        with entities: [KnowledgeEntity],
        includeInPermanentIndex: Bool
    ) async throws -> EntityIndexChange

    func entities(identifiedBy identifiers: [EntityID]) async throws -> [KnowledgeEntity]
    func entities(from source: URL) async throws -> [KnowledgeEntity]
    func allEntities() async throws -> [KnowledgeEntity]
    func permanentlyIndexedEntities() async throws -> [KnowledgeEntity]
    func locallyOnlyEntities() async throws -> [KnowledgeEntity]
    func resolve(_ reference: EntityReference) async throws -> KnowledgeEntity?

    func stageReplacement(
        from source: URL,
        with entities: [KnowledgeEntity]
    ) async throws -> PendingEntityIndexChange

    func stageReplacement(
        from source: URL,
        with entities: [KnowledgeEntity],
        includeInPermanentIndex: Bool
    ) async throws -> PendingEntityIndexChange

    func pendingIndexChanges() async throws -> [PendingEntityIndexChange]
    func acknowledgeIndexChange(identifiedBy identifier: UUID) async throws
    func requiresFullRebuild() async throws -> Bool
    func markFullRebuildCompleted() async throws
}

public extension EntityCatalog {
    /// Compatibility fallback for catalogs that do not persist exact source
    /// membership. Catalogs with source records should override this method;
    /// path containment cannot distinguish overlapping enrolled roots.
    func entities(from source: URL) async throws -> [KnowledgeEntity] {
        let sourceComponents = source.standardizedFileURL.pathComponents
        return try await allEntities()
            .filter { entity in
                let entityComponents = entity.source.fileURL.standardizedFileURL
                    .pathComponents
                guard sourceComponents.count <= entityComponents.count else {
                    return false
                }
                return entityComponents.prefix(sourceComponents.count)
                    .elementsEqual(sourceComponents)
            }
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    func stageReplacement(
        from source: URL,
        with entities: [KnowledgeEntity]
    ) async throws -> PendingEntityIndexChange {
        PendingEntityIndexChange(
            change: try await replaceEntities(from: source, with: entities)
        )
    }

    func stageReplacement(
        from source: URL,
        with entities: [KnowledgeEntity],
        includeInPermanentIndex: Bool
    ) async throws -> PendingEntityIndexChange {
        PendingEntityIndexChange(
            change: try await replaceEntities(
                from: source,
                with: entities,
                includeInPermanentIndex: includeInPermanentIndex
            )
        )
    }

    func pendingIndexChanges() async throws -> [PendingEntityIndexChange] {
        []
    }

    func acknowledgeIndexChange(identifiedBy identifier: UUID) async throws {}

    func requiresFullRebuild() async throws -> Bool {
        false
    }

    func markFullRebuildCompleted() async throws {}
}

public enum EntityReference: Codable, Hashable, Sendable {
    case entityID(EntityID)
    case file(URL)
    case sourceAnchor(SourceAnchor)
    case providerLocal(providerID: String, value: String)
}

public enum ContextRelevance: String, Codable, CaseIterable, Hashable, Sendable {
    case selected
    case visible
    case currentTask
    case activeProject
    case open
    case neighboring
    case recent
}

public struct ContextContribution: Codable, Hashable, Sendable {
    public var reference: EntityReference
    public var relevance: ContextRelevance
    public var expiresAt: Date

    public init(
        reference: EntityReference,
        relevance: ContextRelevance,
        expiresAt: Date
    ) {
        self.reference = reference
        self.relevance = relevance
        self.expiresAt = expiresAt
    }
}

public struct ContextSnapshot: Codable, Equatable, Sendable {
    public var providerID: String
    public var observedAt: Date
    public var contributions: [ContextContribution]

    public init(
        providerID: String,
        observedAt: Date,
        contributions: [ContextContribution]
    ) {
        self.providerID = providerID
        self.observedAt = observedAt
        self.contributions = contributions
    }
}

public protocol ContextProvider: Sendable {
    var id: String { get }
    func contextSnapshot() async throws -> ContextSnapshot
}

public struct ContextSignal: Equatable, Sendable {
    public var providerID: String
    public var relevance: ContextRelevance
    public var observedAt: Date
    public var expiresAt: Date

    public init(
        providerID: String,
        relevance: ContextRelevance,
        observedAt: Date,
        expiresAt: Date
    ) {
        self.providerID = providerID
        self.relevance = relevance
        self.observedAt = observedAt
        self.expiresAt = expiresAt
    }
}

public struct ResolvedContextItem: Equatable, Sendable {
    public var entity: KnowledgeEntity
    public var signals: [ContextSignal]
    public var score: Int

    public init(entity: KnowledgeEntity, signals: [ContextSignal], score: Int) {
        self.entity = entity
        self.signals = signals
        self.score = score
    }
}

public struct UnresolvedContextContribution: Equatable, Sendable {
    public var providerID: String
    public var observedAt: Date
    public var contribution: ContextContribution

    public init(
        providerID: String,
        observedAt: Date,
        contribution: ContextContribution
    ) {
        self.providerID = providerID
        self.observedAt = observedAt
        self.contribution = contribution
    }
}

public struct CurrentContext: Equatable, Sendable {
    public var resolved: [ResolvedContextItem]
    public var unresolved: [UnresolvedContextContribution]

    public init(
        resolved: [ResolvedContextItem],
        unresolved: [UnresolvedContextContribution]
    ) {
        self.resolved = resolved
        self.unresolved = unresolved
    }
}

public protocol ContextRankingPolicy: Sendable {
    func score(for signals: [ContextSignal]) -> Int
}

public protocol ContextPublisher: Sendable {
    func publish(_ context: CurrentContext) async throws
}

public protocol DocumentOpener: Sendable {
    var id: String { get }
    func canOpen(_ entity: KnowledgeEntity) async -> Bool
    func open(_ entity: KnowledgeEntity) async throws
}

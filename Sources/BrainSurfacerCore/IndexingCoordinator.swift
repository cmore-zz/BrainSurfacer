import BrainSurfacerModel
import Foundation

public actor IndexingCoordinator {
    private let catalog: any EntityCatalog
    private let permanentIndex: any PermanentEntityIndex

    public init(
        catalog: any EntityCatalog,
        permanentIndex: any PermanentEntityIndex
    ) {
        self.catalog = catalog
        self.permanentIndex = permanentIndex
    }

    public func replaceEntities(
        from source: URL,
        with entities: [KnowledgeEntity]
    ) async throws {
        try await replayPendingChanges()
        let pending = try await catalog.stageReplacement(from: source, with: entities)
        try await applyAndAcknowledge(pending)
    }

    public func replayPendingChanges() async throws {
        let pendingChanges = try await catalog.pendingIndexChanges()
        for pending in pendingChanges {
            try await applyAndAcknowledge(pending)
        }
    }

    private func applyAndAcknowledge(
        _ pending: PendingEntityIndexChange
    ) async throws {
        try await permanentIndex.apply(pending.change)
        try await catalog.acknowledgeIndexChange(identifiedBy: pending.id)
    }
}

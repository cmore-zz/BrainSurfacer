import BrainSurfacerModel
import Foundation

public actor IndexingCoordinator {
    private let catalog: any EntityCatalog
    private let permanentIndex: any PermanentEntityIndex
    private var didPrepareFullRebuild = false

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
        if try await prepareForReindex() == false {
            try await replayPendingChanges()
        }
        let pending = try await catalog.stageReplacement(from: source, with: entities)
        try await applyAndAcknowledge(pending)
    }

    public func replayPendingChanges() async throws {
        guard try await prepareForReindex() == false else {
            return
        }
        let pendingChanges = try await catalog.pendingIndexChanges()
        for pending in pendingChanges {
            try await applyAndAcknowledge(pending)
        }
    }

    @discardableResult
    public func prepareForReindex() async throws -> Bool {
        guard try await catalog.requiresFullRebuild() else {
            didPrepareFullRebuild = false
            return false
        }
        if !didPrepareFullRebuild {
            try await permanentIndex.reset()
            didPrepareFullRebuild = true
        }
        return true
    }

    public func completeFullRebuild() async throws {
        guard didPrepareFullRebuild else {
            return
        }
        guard try await catalog.requiresFullRebuild() else {
            didPrepareFullRebuild = false
            return
        }
        try await catalog.markFullRebuildCompleted()
        didPrepareFullRebuild = false
    }

    private func applyAndAcknowledge(
        _ pending: PendingEntityIndexChange
    ) async throws {
        try await permanentIndex.apply(pending.change)
        try await catalog.acknowledgeIndexChange(identifiedBy: pending.id)
    }
}

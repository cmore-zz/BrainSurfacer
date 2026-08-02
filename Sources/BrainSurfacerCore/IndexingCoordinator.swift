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
        if try await ensurePreparedForReindex() == false {
            try await replayPendingChangesAfterPreparation()
        }
        let pending = try await catalog.stageReplacement(from: source, with: entities)
        try await applyAndAcknowledge(pending)
    }

    public func replayPendingChanges() async throws {
        guard try await ensurePreparedForReindex() == false else {
            return
        }
        try await replayPendingChangesAfterPreparation()
    }

    public func entities(from source: URL) async throws -> [KnowledgeEntity] {
        try await catalog.entities(from: source)
    }

    private func replayPendingChangesAfterPreparation() async throws {
        let pendingChanges = try await catalog.pendingIndexChanges()
        for pending in pendingChanges {
            try await applyAndAcknowledge(pending)
        }
    }

    @discardableResult
    public func prepareForReindex() async throws -> Bool {
        try await prepareForReindexIfNeeded(resetPreparedRebuild: true)
    }

    private func ensurePreparedForReindex() async throws -> Bool {
        try await prepareForReindexIfNeeded(resetPreparedRebuild: false)
    }

    private func prepareForReindexIfNeeded(
        resetPreparedRebuild: Bool
    ) async throws -> Bool {
        guard try await catalog.requiresFullRebuild() else {
            didPrepareFullRebuild = false
            return false
        }
        if !didPrepareFullRebuild || resetPreparedRebuild {
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

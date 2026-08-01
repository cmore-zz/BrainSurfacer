import BrainSurfacerCore
import BrainSurfacerModel
import Foundation
import Testing

@Test
func persistentCatalogReconcilesStaleEntitiesAcrossRelaunch() async throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }

    let source = URL(fileURLWithPath: "/notes/brain.org")
    let first = makePersistentEntity(id: "first", source: source)
    let second = makePersistentEntity(id: "second", source: source)
    let initialCatalog = PersistentEntityCatalog(storageURL: fixture.catalogURL)
    let initialCoordinator = IndexingCoordinator(
        catalog: initialCatalog,
        permanentIndex: SilentIndex()
    )

    try await initialCoordinator.replaceEntities(
        from: source,
        with: [first, second]
    )

    let relaunchedCatalog = PersistentEntityCatalog(storageURL: fixture.catalogURL)
    let recordingIndex = PersistentRecordingIndex()
    let relaunchedCoordinator = IndexingCoordinator(
        catalog: relaunchedCatalog,
        permanentIndex: recordingIndex
    )
    try await relaunchedCoordinator.replaceEntities(from: source, with: [second])

    let changes = await recordingIndex.changes
    #expect(changes.count == 1)
    #expect(changes[0].removals == [first.id])
    #expect(changes[0].upserts.map(\.id) == [second.id])
    #expect(try await relaunchedCatalog.allEntities().map(\.id) == [second.id])
}

@Test
func failedIndexMutationIsReplayedAndAcknowledgedAfterRelaunch() async throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }

    let source = URL(fileURLWithPath: "/notes/recovery.md")
    let entity = makePersistentEntity(id: "recovery", source: source)
    let firstCatalog = PersistentEntityCatalog(storageURL: fixture.catalogURL)
    let failingCoordinator = IndexingCoordinator(
        catalog: firstCatalog,
        permanentIndex: AlwaysFailingIndex()
    )

    await #expect(throws: PersistentIndexFailure.self) {
        try await failingCoordinator.replaceEntities(from: source, with: [entity])
    }
    let pendingAfterFailure = try await firstCatalog.pendingIndexChanges()
    #expect(pendingAfterFailure.count == 1)

    let relaunchedCatalog = PersistentEntityCatalog(storageURL: fixture.catalogURL)
    let recordingIndex = PersistentRecordingIndex()
    let recoveryCoordinator = IndexingCoordinator(
        catalog: relaunchedCatalog,
        permanentIndex: recordingIndex
    )
    try await recoveryCoordinator.replayPendingChanges()

    let replayedChanges = await recordingIndex.changes
    #expect(replayedChanges.count == 1)
    #expect(replayedChanges[0].upserts.map(\.id) == [entity.id])
    let pendingAfterRecovery = try await relaunchedCatalog.pendingIndexChanges()
    #expect(pendingAfterRecovery.isEmpty)
}

private struct CatalogFixture {
    let directoryURL: URL
    let catalogURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrainSurfacerCatalogTests-\(UUID().uuidString)")
        catalogURL = directoryURL.appendingPathComponent("catalog.json")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private struct PersistentIndexFailure: Error {}

private actor AlwaysFailingIndex: PermanentEntityIndex {
    func apply(_ change: EntityIndexChange) throws {
        throw PersistentIndexFailure()
    }
}

private actor SilentIndex: PermanentEntityIndex {
    func apply(_ change: EntityIndexChange) {}
}

private actor PersistentRecordingIndex: PermanentEntityIndex {
    private(set) var changes: [EntityIndexChange] = []

    func apply(_ change: EntityIndexChange) {
        changes.append(change)
    }
}

private func makePersistentEntity(
    id: String,
    source: URL
) -> KnowledgeEntity {
    KnowledgeEntity(
        id: EntityID(rawValue: id),
        kind: .heading,
        title: id.capitalized,
        source: SourceAnchor(fileURL: source)
    )
}

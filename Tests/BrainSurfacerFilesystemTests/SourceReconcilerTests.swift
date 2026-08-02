import BrainSurfacerCore
import BrainSurfacerFilesystem
import BrainSurfacerModel
import Foundation
import Testing

@Test
func reconciliationCommitsFingerprintsAfterIndexingAndRemovesConfirmedDeletions() async throws {
    let fixture = try ReconciliationFixture()
    defer { fixture.remove() }

    let fileURL = fixture.source.url.appending(path: "Plan.md")
    try "# Initial plan".write(to: fileURL, atomically: true, encoding: .utf8)

    let catalog = InMemoryEntityCatalog()
    let index = ReconciliationRecordingIndex()
    let coordinator = IndexingCoordinator(catalog: catalog, permanentIndex: index)
    let fingerprints = SourceFingerprintStore(storageURL: fixture.fingerprintURL)
    let reconciler = SourceReconciler(
        fingerprintStore: fingerprints,
        coordinator: coordinator
    )

    let initial = try await reconciler.reconcile(fixture.source)
    let unchanged = try await reconciler.reconcile(fixture.source)

    #expect(initial.parsedFileCount == 1)
    #expect(unchanged.parsedFileCount == 0)
    #expect(unchanged.reusedFileCount == 1)
    #expect(await fingerprints.fingerprints(for: fixture.source.url).count == 1)
    let indexedBeforeDeletion = await catalog.entities(from: fixture.source.url)

    try FileManager.default.removeItem(at: fileURL)
    let deleted = try await reconciler.reconcile(fixture.source)
    let changes = await index.changes
    let deletionChange = try #require(changes.last)

    #expect(deleted.entities.isEmpty)
    #expect(await catalog.entities(from: fixture.source.url).isEmpty)
    #expect(await fingerprints.fingerprints(for: fixture.source.url).isEmpty)
    #expect(deletionChange.removals == Set(indexedBeforeDeletion.map(\.id)))
}

@Test
func failedIndexingDoesNotCommitNewFingerprints() async throws {
    let fixture = try ReconciliationFixture()
    defer { fixture.remove() }

    try "# Retry me".write(
        to: fixture.source.url.appending(path: "Retry.md"),
        atomically: true,
        encoding: .utf8
    )
    let fingerprints = SourceFingerprintStore(storageURL: fixture.fingerprintURL)
    let reconciler = SourceReconciler(
        fingerprintStore: fingerprints,
        coordinator: IndexingCoordinator(
            catalog: InMemoryEntityCatalog(),
            permanentIndex: ReconciliationFailingIndex()
        )
    )

    await #expect(throws: ReconciliationIndexFailure.self) {
        try await reconciler.reconcile(fixture.source)
    }
    #expect(await fingerprints.fingerprints(for: fixture.source.url).isEmpty)
}

@Test
func fingerprintWriteFailureDoesNotTurnSuccessfulIndexingIntoFailure() async throws {
    let fixture = try ReconciliationFixture()
    defer { fixture.remove() }

    try "# Still indexed".write(
        to: fixture.source.url.appending(path: "Indexed.md"),
        atomically: true,
        encoding: .utf8
    )
    let fileInsteadOfDirectory = fixture.directoryURL.appending(path: "blocked")
    try "not a directory".write(
        to: fileInsteadOfDirectory,
        atomically: true,
        encoding: .utf8
    )
    let catalog = InMemoryEntityCatalog()
    let index = ReconciliationRecordingIndex()
    let reconciler = SourceReconciler(
        fingerprintStore: SourceFingerprintStore(
            storageURL: fileInsteadOfDirectory.appending(path: "fingerprints.json")
        ),
        coordinator: IndexingCoordinator(catalog: catalog, permanentIndex: index)
    )

    let result = try await reconciler.reconcile(fixture.source)

    #expect(result.parsedFileCount == 1)
    #expect(await catalog.entities(from: fixture.source.url).count == 2)
    #expect(await index.changes.count == 1)
}

@Test
func cancelledReconciliationStopsBeforeIndexing() async throws {
    let fixture = try ReconciliationFixture()
    defer { fixture.remove() }

    try "# Cancel me".write(
        to: fixture.source.url.appending(path: "Cancel.md"),
        atomically: true,
        encoding: .utf8
    )
    let fingerprints = SourceFingerprintStore(storageURL: fixture.fingerprintURL)
    let index = ReconciliationRecordingIndex()
    let reconciler = SourceReconciler(
        fingerprintStore: fingerprints,
        coordinator: IndexingCoordinator(
            catalog: InMemoryEntityCatalog(),
            permanentIndex: index
        )
    )
    let reconciliation = Task {
        withUnsafeCurrentTask { task in
            task?.cancel()
        }
        return try await reconciler.reconcile(fixture.source)
    }

    await #expect(throws: CancellationError.self) {
        try await reconciliation.value
    }
    #expect(await index.changes.isEmpty)
    #expect(await fingerprints.fingerprints(for: fixture.source.url).isEmpty)
}

private struct ReconciliationFixture {
    let directoryURL: URL
    let source: SourceDirectory
    let fingerprintURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "BrainSurfacerReconcile-\(UUID().uuidString)", directoryHint: .isDirectory)
        let sourceURL = directoryURL.appending(path: "Notes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: sourceURL,
            withIntermediateDirectories: true
        )
        source = SourceDirectory(url: sourceURL)
        fingerprintURL = directoryURL.appending(path: "fingerprints.json")
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private actor ReconciliationRecordingIndex: PermanentEntityIndex {
    private(set) var changes: [EntityIndexChange] = []

    func apply(_ change: EntityIndexChange) {
        changes.append(change)
    }

    func reset() {}
}

private struct ReconciliationIndexFailure: Error {}

private actor ReconciliationFailingIndex: PermanentEntityIndex {
    func apply(_ change: EntityIndexChange) throws {
        throw ReconciliationIndexFailure()
    }

    func reset() {}
}

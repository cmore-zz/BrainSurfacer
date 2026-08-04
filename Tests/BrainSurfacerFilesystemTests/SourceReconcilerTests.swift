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
func reconciliationRemovesFilesExcludedByAChangedSourcePolicy() async throws {
    let fixture = try ReconciliationFixture()
    defer { fixture.remove() }

    let retainedFile = fixture.source.url.appending(path: "Retained.md")
    let excludedFile = fixture.source.url.appending(path: "Excluded.md")
    try "# Retained".write(to: retainedFile, atomically: true, encoding: .utf8)
    try "# Excluded".write(to: excludedFile, atomically: true, encoding: .utf8)

    let catalog = InMemoryEntityCatalog()
    let index = ReconciliationRecordingIndex()
    let fingerprints = SourceFingerprintStore(storageURL: fixture.fingerprintURL)
    let reconciler = SourceReconciler(
        fingerprintStore: fingerprints,
        coordinator: IndexingCoordinator(catalog: catalog, permanentIndex: index)
    )

    _ = try await reconciler.reconcile(fixture.source)
    let initiallyIndexed = await catalog.entities(from: fixture.source.url)
    let excludedIDs = Set(initiallyIndexed.filter {
        $0.source.fileURL.standardizedFileURL == excludedFile.standardizedFileURL
    }.map(\.id))
    #expect(!excludedIDs.isEmpty)
    let filteredSource = SourceDirectory(
        url: fixture.source.url,
        pathPolicy: SourcePathPolicy(excludePatterns: ["Excluded.md"])
    )
    let filtered = try await reconciler.reconcile(filteredSource)
    let remaining = await catalog.entities(from: fixture.source.url)
    let policyChange = try #require(await index.changes.last)

    #expect(filtered.fileCount == 1)
    #expect(filtered.reusedFileCount == 1)
    #expect(filtered.fingerprints.count == 1)
    #expect(remaining.allSatisfy {
        $0.source.fileURL.standardizedFileURL == retainedFile.standardizedFileURL
    })
    #expect(policyChange.removals == excludedIDs)
}

@Test
func reconciliationRevokesAndRestoresDocumentsUsingMetadataOptOut() async throws {
    let fixture = try ReconciliationFixture()
    defer { fixture.remove() }

    let fileURL = fixture.source.url.appending(path: "Private.md")
    try "# Initially searchable\nPrivate details".write(
        to: fileURL,
        atomically: true,
        encoding: .utf8
    )
    let catalog = InMemoryEntityCatalog()
    let index = ReconciliationRecordingIndex()
    let fingerprints = SourceFingerprintStore(storageURL: fixture.fingerprintURL)
    let reconciler = SourceReconciler(
        fingerprintStore: fingerprints,
        coordinator: IndexingCoordinator(catalog: catalog, permanentIndex: index)
    )
    _ = try await reconciler.reconcile(fixture.source)
    let initialIDs = Set(
        await catalog.entities(from: fixture.source.url).map(\.id)
    )
    #expect(!initialIDs.isEmpty)

    try """
    ---
    brainsurfacer-index: false
    ---
    # No longer searchable
    Private details
    """.write(to: fileURL, atomically: true, encoding: .utf8)
    let excluded = try await reconciler.reconcile(fixture.source)
    let exclusionChange = try #require(await index.changes.last)

    #expect(excluded.entities.isEmpty)
    #expect(await catalog.entities(from: fixture.source.url).isEmpty)
    #expect(exclusionChange.removals == initialIDs)
    #expect(await fingerprints.fingerprints(for: fixture.source.url)[
        fileURL.standardizedFileURL
    ]?.wasExcludedByDocumentMetadata == true)

    try "# Searchable again\nRestored details".write(
        to: fileURL,
        atomically: true,
        encoding: .utf8
    )
    let restored = try await reconciler.reconcile(fixture.source)

    #expect(restored.parsedFileCount == 1)
    #expect(await catalog.entities(from: fixture.source.url).contains {
        $0.body?.contains("Restored details") == true
    })
}

@Test
func reconciliationRevokesAndRestoresDataAcrossIndexingModes() async throws {
    let fixture = try ReconciliationFixture()
    defer { fixture.remove() }

    try """
    # Launch plan
    Secret launch details at https://example.com/private.
    """.write(
        to: fixture.source.url.appending(path: "Plan.md"),
        atomically: true,
        encoding: .utf8
    )
    let catalog = InMemoryEntityCatalog()
    let index = ReconciliationRecordingIndex()
    let fingerprints = SourceFingerprintStore(storageURL: fixture.fingerprintURL)
    let reconciler = SourceReconciler(
        fingerprintStore: fingerprints,
        coordinator: IndexingCoordinator(catalog: catalog, permanentIndex: index)
    )

    let full = try await reconciler.reconcile(fixture.source)
    #expect(full.entities.contains { $0.body?.contains("Secret launch") == true })

    let metadataSource = SourceDirectory(
        url: fixture.source.url,
        indexingMode: .metadataOnly
    )
    let metadata = try await reconciler.reconcile(metadataSource)
    let metadataCatalog = await catalog.entities(from: fixture.source.url)
    let metadataChange = try #require(await index.changes.last)
    #expect(metadata.parsedFileCount == 1)
    #expect(metadataCatalog.allSatisfy {
        $0.body == nil && $0.summary == nil && $0.links.isEmpty
    })
    #expect(metadataChange.upserts.allSatisfy {
        $0.body == nil && $0.summary == nil && $0.links.isEmpty
    })
    #expect(await fingerprints.fingerprints(for: fixture.source.url).values.allSatisfy {
        $0.indexingMode == .metadataOnly
    })

    let pausedSource = SourceDirectory(
        url: fixture.source.url,
        indexingMode: .paused
    )
    let paused = try await reconciler.reconcile(pausedSource)
    let pauseChange = try #require(await index.changes.last)
    #expect(paused.fileCount == 0)
    #expect(await catalog.entities(from: fixture.source.url).isEmpty)
    #expect(await fingerprints.fingerprints(for: fixture.source.url).isEmpty)
    #expect(pauseChange.removals == Set(metadataCatalog.map(\.id)))

    let resumed = try await reconciler.reconcile(fixture.source)
    #expect(resumed.parsedFileCount == 1)
    #expect(await catalog.entities(from: fixture.source.url).contains {
        $0.body?.contains("Secret launch") == true
    })
}

@Test
func reconciliationMovesAStableSourceBetweenLocalAndAppleDiscoveryWithoutReparsing() async throws {
    let fixture = try ReconciliationFixture()
    defer { fixture.remove() }

    try "# Discovery boundary\nSearchable locally".write(
        to: fixture.source.url.appending(path: "Discovery.md"),
        atomically: true,
        encoding: .utf8
    )
    let catalog = InMemoryEntityCatalog()
    let index = ReconciliationRecordingIndex()
    let fingerprints = SourceFingerprintStore(storageURL: fixture.fingerprintURL)
    let reconciler = SourceReconciler(
        fingerprintStore: fingerprints,
        coordinator: IndexingCoordinator(catalog: catalog, permanentIndex: index)
    )

    let shared = try await reconciler.reconcile(fixture.source)
    let sharedCatalog = await catalog.entities(from: fixture.source.url)
    #expect(shared.parsedFileCount == 1)
    #expect(!sharedCatalog.isEmpty)
    #expect(try await catalog.permanentlyIndexedEntities() == sharedCatalog)

    let localSource = SourceDirectory(
        url: fixture.source.url,
        discoveryScope: .localOnly
    )
    let local = try await reconciler.reconcile(localSource)
    let localCatalog = await catalog.entities(from: fixture.source.url)
    let localChange = try #require(await index.changes.last)

    #expect(local.parsedFileCount == 0)
    #expect(local.reusedFileCount == 1)
    #expect(local.fingerprints == shared.fingerprints)
    #expect(localCatalog == sharedCatalog)
    #expect(try await catalog.permanentlyIndexedEntities().isEmpty)
    #expect(localChange.upserts.isEmpty)
    #expect(localChange.removals == Set(sharedCatalog.map(\.id)))

    let restored = try await reconciler.reconcile(fixture.source)
    let restoredChange = try #require(await index.changes.last)

    #expect(restored.parsedFileCount == 0)
    #expect(restored.reusedFileCount == 1)
    #expect(restored.fingerprints == local.fingerprints)
    #expect(restoredChange.upserts.map(\.id) == sharedCatalog.map(\.id))
    #expect(restoredChange.removals.isEmpty)
    #expect(try await catalog.permanentlyIndexedEntities() == sharedCatalog)
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
func pausedReconciliationReportsFingerprintRemovalFailure() async throws {
    let fixture = try ReconciliationFixture()
    defer { fixture.remove() }

    let fileInsteadOfDirectory = fixture.directoryURL.appending(path: "blocked")
    try "not a directory".write(
        to: fileInsteadOfDirectory,
        atomically: true,
        encoding: .utf8
    )
    let catalog = InMemoryEntityCatalog()
    let reconciler = SourceReconciler(
        fingerprintStore: SourceFingerprintStore(
            storageURL: fileInsteadOfDirectory.appending(path: "fingerprints.json")
        ),
        coordinator: IndexingCoordinator(
            catalog: catalog,
            permanentIndex: ReconciliationRecordingIndex()
        )
    )
    var didThrow = false

    do {
        _ = try await reconciler.reconcile(
            SourceDirectory(url: fixture.source.url, indexingMode: .paused)
        )
    } catch {
        didThrow = true
    }

    #expect(didThrow)
    #expect(await catalog.entities(from: fixture.source.url).isEmpty)
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

@Test
func removalWaitsForInFlightReconciliation() async throws {
    let fixture = try ReconciliationFixture()
    defer { fixture.remove() }

    try "# Remove after indexing".write(
        to: fixture.source.url.appending(path: "Remove.md"),
        atomically: true,
        encoding: .utf8
    )
    let catalog = InMemoryEntityCatalog()
    let index = ReconciliationBlockingIndex()
    let reconciler = SourceReconciler(
        fingerprintStore: SourceFingerprintStore(
            storageURL: fixture.fingerprintURL
        ),
        coordinator: IndexingCoordinator(catalog: catalog, permanentIndex: index)
    )
    let reconciliation = Task {
        try await reconciler.reconcile(fixture.source)
    }
    await index.waitUntilFirstApplyStarts()

    let removal = Task {
        try await reconciler.remove(fixture.source)
    }
    try await Task.sleep(for: .milliseconds(50))

    #expect(await index.applyCallCount == 1)
    await index.releaseFirstApply()
    _ = try await reconciliation.value
    try await removal.value

    #expect(await index.applyCallCount == 2)
    #expect(await catalog.entities(from: fixture.source.url).isEmpty)
    #expect(await index.indexedEntityIDs.isEmpty)
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

private actor ReconciliationBlockingIndex: PermanentEntityIndex {
    private(set) var applyCallCount = 0
    private(set) var indexedEntityIDs: Set<EntityID> = []
    private var firstApplyRelease: CheckedContinuation<Void, Never>?
    private var firstApplyStartWaiters: [CheckedContinuation<Void, Never>] = []

    func apply(_ change: EntityIndexChange) async {
        applyCallCount += 1
        if applyCallCount == 1 {
            let waiters = firstApplyStartWaiters
            firstApplyStartWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                firstApplyRelease = continuation
            }
        }
        indexedEntityIDs.subtract(change.removals)
        indexedEntityIDs.formUnion(change.upserts.map(\.id))
    }

    func reset() {}

    func waitUntilFirstApplyStarts() async {
        guard applyCallCount == 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            firstApplyStartWaiters.append(continuation)
        }
    }

    func releaseFirstApply() {
        firstApplyRelease?.resume()
        firstApplyRelease = nil
    }
}

private struct ReconciliationIndexFailure: Error {}

private actor ReconciliationFailingIndex: PermanentEntityIndex {
    func apply(_ change: EntityIndexChange) throws {
        throw ReconciliationIndexFailure()
    }

    func reset() {}
}

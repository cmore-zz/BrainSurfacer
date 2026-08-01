import BrainSurfacerCore
import BrainSurfacerFilesystem
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

@Test
func corruptCatalogTriggersAFullProjectionRebuild() async throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }

    let source = URL(fileURLWithPath: "/notes/recovered.md")
    let stale = makePersistentEntity(id: "stale", source: source)
    let initialCatalog = PersistentEntityCatalog(storageURL: fixture.catalogURL)
    _ = try await initialCatalog.replaceEntities(from: source, with: [stale])
    try Data("not valid json".utf8).write(to: fixture.catalogURL)

    let recovered = makePersistentEntity(id: "recovered", source: source)
    let catalog = PersistentEntityCatalog(storageURL: fixture.catalogURL)
    let index = RebuildRecordingIndex(indexedIDs: [stale.id])
    let coordinator = IndexingCoordinator(catalog: catalog, permanentIndex: index)

    #expect(try await coordinator.prepareForReindex())
    #expect(await index.resetCount == 1)
    try await coordinator.replaceEntities(from: source, with: [recovered])
    try await coordinator.completeFullRebuild()

    #expect(await index.indexedIDs == [recovered.id])
    #expect(try await catalog.requiresFullRebuild() == false)
    #expect(try await catalog.allEntities().map(\.id) == [recovered.id])
    let quarantinedFiles = try FileManager.default.contentsOfDirectory(
        at: fixture.directoryURL,
        includingPropertiesForKeys: nil
    ).filter {
        $0.lastPathComponent.hasPrefix("catalog.json.invalid-")
    }
    #expect(quarantinedFiles.count == 1)
}

@Test
func incompatibleCatalogSchemaTriggersAFullProjectionRebuild() async throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }

    let source = URL(fileURLWithPath: "/notes/versioned.md")
    let entity = makePersistentEntity(id: "versioned", source: source)
    let initialCatalog = PersistentEntityCatalog(storageURL: fixture.catalogURL)
    _ = try await initialCatalog.replaceEntities(from: source, with: [entity])
    let data = try Data(contentsOf: fixture.catalogURL)
    let currentJSON = try #require(String(data: data, encoding: .utf8))
    let incompatibleJSON = currentJSON.replacingOccurrences(
        of: "\"schemaVersion\":1",
        with: "\"schemaVersion\":999"
    )
    #expect(incompatibleJSON != currentJSON)
    try Data(incompatibleJSON.utf8).write(to: fixture.catalogURL)

    let catalog = PersistentEntityCatalog(storageURL: fixture.catalogURL)
    let index = RebuildRecordingIndex(indexedIDs: [entity.id])
    let coordinator = IndexingCoordinator(catalog: catalog, permanentIndex: index)

    #expect(try await coordinator.prepareForReindex())
    #expect(await index.resetCount == 1)
    #expect(await index.indexedIDs.isEmpty)
    let rebuildRequired = try await catalog.requiresFullRebuild()
    #expect(rebuildRequired)
}

@Test
func structuralIdentitySurvivesDuplicateRenamesAndSourceRootMove() async throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }

    let oldRoot = fixture.directoryURL.appendingPathComponent("OldRoot", isDirectory: true)
    let newRoot = fixture.directoryURL.appendingPathComponent("NewRoot", isDirectory: true)
    try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
    let oldFile = oldRoot.appendingPathComponent("Plan.md")
    let initial = OutlineParser().parse(
        SourceDocument(
            fileURL: oldFile,
            format: .markdown,
            contents: """
            # Initial plan
            ## Repeated
            same evidence
            ## Repeated
            same evidence
            """
        )
    )
    let catalog = PersistentEntityCatalog(storageURL: fixture.catalogURL)

    let firstChange = try await catalog.replaceEntities(from: oldRoot, with: initial)
    let firstIdentifiers = Set(firstChange.upserts.map(\.id))
    #expect(firstIdentifiers.isDisjoint(with: Set(initial.map(\.id))))

    try FileManager.default.moveItem(at: oldRoot, to: newRoot)
    let movedFile = newRoot.appendingPathComponent("Renamed.md")
    let rescanned = OutlineParser().parse(
        SourceDocument(
            fileURL: movedFile,
            format: .markdown,
            contents: """
            # Renamed plan
            ## Repeated
            same evidence
            ## Repeated
            same evidence
            """
        )
    )

    let movedChange = try await catalog.replaceEntities(from: newRoot, with: rescanned)

    #expect(Set(movedChange.upserts.map(\.id)) == firstIdentifiers)
    #expect(movedChange.removals.isEmpty)
    #expect(Set(try await catalog.allEntities().map(\.id)) == firstIdentifiers)
    #expect(
        movedChange.upserts
            .filter { $0.kind != .note }
            .allSatisfy { entity in
                entity.relationships.allSatisfy { firstIdentifiers.contains($0.target) }
            }
    )
}

@Test
func localExplicitIdentitySurvivesSimultaneousRenameAndContentEdit() async throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }

    let root = fixture.directoryURL.appendingPathComponent("Notes", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("Plan.md")
    let parser = OutlineParser()
    let initial = parser.parse(
        SourceDocument(
            fileURL: file,
            format: .markdown,
            contents: "# Alpha ^stable-anchor\nold body"
        )
    )
    let catalog = PersistentEntityCatalog(storageURL: fixture.catalogURL)
    let first = try await catalog.replaceEntities(from: root, with: initial)
    let firstHeadingID = try #require(first.upserts.first { $0.kind == .heading }?.id)

    let edited = parser.parse(
        SourceDocument(
            fileURL: file,
            format: .markdown,
            contents: "# Beta ^stable-anchor\ncompletely new body"
        )
    )
    let second = try await catalog.replaceEntities(from: root, with: edited)
    let secondHeading = try #require(second.upserts.first { $0.kind == .heading })

    #expect(secondHeading.id == firstHeadingID)
    #expect(secondHeading.title == "Beta")
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

    func reset() {}
}

private actor SilentIndex: PermanentEntityIndex {
    func apply(_ change: EntityIndexChange) {}
    func reset() {}
}

private actor PersistentRecordingIndex: PermanentEntityIndex {
    private(set) var changes: [EntityIndexChange] = []

    func apply(_ change: EntityIndexChange) {
        changes.append(change)
    }

    func reset() {}
}

private actor RebuildRecordingIndex: PermanentEntityIndex {
    private(set) var indexedIDs: Set<EntityID>
    private(set) var resetCount = 0

    init(indexedIDs: Set<EntityID>) {
        self.indexedIDs = indexedIDs
    }

    func apply(_ change: EntityIndexChange) {
        indexedIDs.subtract(change.removals)
        indexedIDs.formUnion(change.upserts.map(\.id))
    }

    func reset() {
        resetCount += 1
        indexedIDs = []
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

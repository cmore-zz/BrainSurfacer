import BrainSurfacerCore
import BrainSurfacerModel
import Foundation
import Testing

@Test
func replacingSourceRemovesStaleEntities() async throws {
    let source = URL(fileURLWithPath: "/tmp/brain.org")
    let anchor = SourceAnchor(fileURL: source)
    let catalog = InMemoryEntityCatalog()
    let index = RecordingIndex()
    let coordinator = IndexingCoordinator(catalog: catalog, permanentIndex: index)
    let first = KnowledgeEntity(
        id: EntityID(rawValue: "first"),
        kind: .heading,
        title: "First",
        source: anchor
    )
    let second = KnowledgeEntity(
        id: EntityID(rawValue: "second"),
        kind: .heading,
        title: "Second",
        source: anchor
    )

    try await coordinator.replaceEntities(from: source, with: [first, second])
    #expect(try await coordinator.entities(from: source).map(\.id) == [first.id, second.id])
    try await coordinator.replaceEntities(from: source, with: [second])

    let changes = await index.changes
    #expect(changes.count == 2)
    #expect(changes[1].removals == [first.id])
    #expect(changes[1].upserts.map(\.id) == [second.id])
    #expect(try await coordinator.entities(from: source).map(\.id) == [second.id])
}

@Test
func permanentIndexesWithoutResetCapabilityFailExplicitly() async {
    let index = ApplyOnlyIndex()

    await #expect(throws: PermanentEntityIndexError.fullResetUnsupported) {
        try await index.reset()
    }
}

private actor RecordingIndex: PermanentEntityIndex {
    private(set) var changes: [EntityIndexChange] = []

    func apply(_ change: EntityIndexChange) {
        changes.append(change)
    }

    func reset() {}
}

private actor ApplyOnlyIndex: PermanentEntityIndex {
    func apply(_ change: EntityIndexChange) {}
}

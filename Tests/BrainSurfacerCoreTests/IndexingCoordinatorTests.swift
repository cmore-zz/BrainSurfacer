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

@Test
func entityCatalogDefaultSourceMembershipUsesPathComponents() async throws {
    let root = URL(fileURLWithPath: "/Users/example/Notes")
    let included = KnowledgeEntity(
        id: EntityID(rawValue: "included"),
        kind: .note,
        title: "Included",
        source: SourceAnchor(fileURL: root.appending(path: "Plan.md"))
    )
    let lookalike = KnowledgeEntity(
        id: EntityID(rawValue: "lookalike"),
        kind: .note,
        title: "Lookalike",
        source: SourceAnchor(
            fileURL: URL(fileURLWithPath: "/Users/example/Notebook/Plan.md")
        )
    )
    let catalog = DefaultMembershipCatalog(entities: [lookalike, included])

    let entities = try await catalog.entities(from: root)

    #expect(entities.map(\.id) == [included.id])
}

@Test
func inTreeCatalogKeepsExactMembershipForOverlappingRoots() async {
    let root = URL(fileURLWithPath: "/Users/example/Notes")
    let nestedRoot = root.appending(path: "Projects")
    let rootEntity = KnowledgeEntity(
        id: EntityID(rawValue: "root"),
        kind: .note,
        title: "Root",
        source: SourceAnchor(fileURL: root.appending(path: "Root.md"))
    )
    let nestedEntity = KnowledgeEntity(
        id: EntityID(rawValue: "nested"),
        kind: .note,
        title: "Nested",
        source: SourceAnchor(fileURL: nestedRoot.appending(path: "Nested.md"))
    )
    let catalog = InMemoryEntityCatalog()
    _ = await catalog.replaceEntities(from: root, with: [rootEntity])
    _ = await catalog.replaceEntities(from: nestedRoot, with: [nestedEntity])

    let rootEntities = await catalog.entities(from: root)
    let nestedEntities = await catalog.entities(from: nestedRoot)

    #expect(rootEntities.map(\.id) == [rootEntity.id])
    #expect(nestedEntities.map(\.id) == [nestedEntity.id])
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

private actor DefaultMembershipCatalog: EntityCatalog {
    private var storedEntities: [KnowledgeEntity]

    init(entities: [KnowledgeEntity]) {
        storedEntities = entities
    }

    func replaceEntities(
        from source: URL,
        with entities: [KnowledgeEntity]
    ) -> EntityIndexChange {
        storedEntities = entities
        return EntityIndexChange(upserts: entities, removals: [])
    }

    func entities(identifiedBy identifiers: [EntityID]) -> [KnowledgeEntity] {
        let identifiers = Set(identifiers)
        return storedEntities.filter { identifiers.contains($0.id) }
    }

    func allEntities() -> [KnowledgeEntity] {
        storedEntities
    }

    func resolve(_ reference: EntityReference) -> KnowledgeEntity? {
        nil
    }
}

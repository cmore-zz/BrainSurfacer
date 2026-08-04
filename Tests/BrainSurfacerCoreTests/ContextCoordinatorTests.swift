import BrainSurfacerCore
import BrainSurfacerModel
import Foundation
import Testing

@Test
func contextSignalsResolveToAndDeduplicateCanonicalEntities() async throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let source = URL(fileURLWithPath: "/notes/Projects.org")
    let note = makeEntity(
        id: "note",
        kind: .note,
        title: "Projects",
        source: source
    )
    let heading = makeEntity(
        id: "heading",
        kind: .heading,
        title: "BrainSurfacer",
        source: source,
        headingPath: ["BrainSurfacer"],
        line: 4
    )
    let catalog = InMemoryEntityCatalog()
    _ = await catalog.replaceEntities(from: source, with: [note, heading])
    let emacs = FakeContextProvider(
        id: "org.gnu.Emacs",
        observedAt: now,
        contributions: [
            ContextContribution(
                reference: .sourceAnchor(
                    SourceAnchor(
                        fileURL: source,
                        headingPath: ["BrainSurfacer"],
                        line: 4
                    )
                ),
                relevance: .visible,
                expiresAt: now.addingTimeInterval(30)
            )
        ]
    )
    let filesystemObserver = FakeContextProvider(
        id: "dev.brainsurfacer.test",
        observedAt: now,
        contributions: [
            ContextContribution(
                reference: .entityID(heading.id),
                relevance: .open,
                expiresAt: now.addingTimeInterval(60)
            )
        ]
    )
    let coordinator = ContextCoordinator(catalog: catalog)

    try await coordinator.refresh(from: emacs)
    try await coordinator.refresh(from: filesystemObserver)
    let context = try await coordinator.currentContext(at: now)

    #expect(context.resolved.count == 1)
    #expect(context.resolved[0].entity.id == heading.id)
    #expect(context.resolved[0].signals.count == 2)
    #expect(Set(context.resolved[0].signals.map(\.relevance)) == [.visible, .open])
    #expect(context.resolved[0].score == 110)
    #expect(context.unresolved.isEmpty)
}

@Test
func aNewProviderSnapshotReplacesItsPreviousState() async throws {
    let now = Date(timeIntervalSince1970: 2_000)
    let source = URL(fileURLWithPath: "/notes/Today.md")
    let note = makeEntity(id: "today", kind: .note, title: "Today", source: source)
    let task = makeEntity(
        id: "task",
        kind: .task,
        title: "Ship context slice",
        source: source,
        headingPath: ["Ship context slice"],
        line: 8
    )
    let catalog = InMemoryEntityCatalog()
    _ = await catalog.replaceEntities(from: source, with: [note, task])
    let provider = FakeContextProvider(
        observedAt: now,
        contributions: [
            ContextContribution(
                reference: .entityID(note.id),
                relevance: .visible,
                expiresAt: now.addingTimeInterval(60)
            )
        ]
    )
    let coordinator = ContextCoordinator(catalog: catalog)
    try await coordinator.refresh(from: provider)

    await provider.update(
        observedAt: now.addingTimeInterval(1),
        contributions: [
            ContextContribution(
                reference: .entityID(task.id),
                relevance: .currentTask,
                expiresAt: now.addingTimeInterval(60)
            )
        ]
    )
    try await coordinator.refresh(from: provider)
    let context = try await coordinator.currentContext(at: now.addingTimeInterval(2))

    #expect(context.resolved.map(\.entity.id) == [task.id])

    await provider.update(
        observedAt: now.addingTimeInterval(3),
        contributions: []
    )
    try await coordinator.refresh(from: provider)
    #expect(
        try await coordinator.currentContext(at: now.addingTimeInterval(3))
            == CurrentContext(resolved: [], unresolved: [])
    )
}

@Test
func unresolvedContextIsRetainedUntilItExpires() async throws {
    let now = Date(timeIntervalSince1970: 3_000)
    let catalog = InMemoryEntityCatalog()
    let coordinator = ContextCoordinator(catalog: catalog)
    let provider = FakeContextProvider(
        id: "md.obsidian",
        observedAt: now,
        contributions: [
            ContextContribution(
                reference: .providerLocal(
                    providerID: "md.obsidian",
                    value: "vault-id:unparsed-note"
                ),
                relevance: .visible,
                expiresAt: now.addingTimeInterval(10)
            )
        ]
    )

    try await coordinator.refresh(from: provider)
    let current = try await coordinator.currentContext(at: now)
    let expired = try await coordinator.currentContext(
        at: now.addingTimeInterval(10)
    )

    #expect(current.resolved.isEmpty)
    #expect(current.unresolved.count == 1)
    #expect(expired == CurrentContext(resolved: [], unresolved: []))
}

@Test
func contextProviderCountIsBoundedByEvictingTheOldestSnapshot() async throws {
    let now = Date(timeIntervalSince1970: 4_000)
    let catalog = InMemoryEntityCatalog()
    let coordinator = ContextCoordinator(catalog: catalog)

    for index in 0...ContextCoordinator.maximumProviderCount {
        let observedAt = now.addingTimeInterval(TimeInterval(index))
        await coordinator.ingest(
            ContextSnapshot(
                providerID: "provider-\(index)",
                observedAt: observedAt,
                contributions: [
                    ContextContribution(
                        reference: .providerLocal(
                            providerID: "provider-\(index)",
                            value: "unresolved"
                        ),
                        relevance: .open,
                        expiresAt: observedAt.addingTimeInterval(300)
                    )
                ]
            )
        )
    }

    let context = try await coordinator.currentContext(
        at: now.addingTimeInterval(TimeInterval(ContextCoordinator.maximumProviderCount))
    )
    let providerIDs = Set(context.unresolved.map(\.providerID))

    #expect(providerIDs.count == ContextCoordinator.maximumProviderCount)
    #expect(!providerIDs.contains("provider-0"))
    #expect(providerIDs.contains("provider-\(ContextCoordinator.maximumProviderCount)"))
}

@Test
func currentContextReportsItsNextExpiration() {
    let first = Date(timeIntervalSince1970: 10)
    let second = Date(timeIntervalSince1970: 20)
    let context = CurrentContext(
        resolved: [],
        unresolved: [
            UnresolvedContextContribution(
                providerID: "provider",
                observedAt: first,
                contribution: ContextContribution(
                    reference: .providerLocal(
                        providerID: "provider",
                        value: "later"
                    ),
                    relevance: .open,
                    expiresAt: second
                )
            ),
            UnresolvedContextContribution(
                providerID: "provider",
                observedAt: first,
                contribution: ContextContribution(
                    reference: .providerLocal(
                        providerID: "provider",
                        value: "first"
                    ),
                    relevance: .visible,
                    expiresAt: first
                )
            )
        ]
    )

    #expect(context.nextExpiration == first)
}

private func makeEntity(
    id: String,
    kind: KnowledgeEntity.Kind,
    title: String,
    source: URL,
    headingPath: [String] = [],
    line: Int? = nil
) -> KnowledgeEntity {
    KnowledgeEntity(
        id: EntityID(rawValue: id),
        kind: kind,
        title: title,
        source: SourceAnchor(
            fileURL: source,
            headingPath: headingPath,
            line: line
        )
    )
}

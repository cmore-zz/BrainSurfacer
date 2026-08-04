import BrainSurfacerCore
import BrainSurfacerModel
import Foundation
import Testing

@Test
func catalogSearchFindsLocalOnlyEntitiesWithoutPermanentEnrollment() async throws {
    let catalog = InMemoryEntityCatalog()
    let localSource = URL(fileURLWithPath: "/notes/private.md")
    let publicSource = URL(fileURLWithPath: "/notes/public.md")
    let local = KnowledgeEntity(
        id: EntityID(rawValue: "local"),
        kind: .note,
        title: "Private launch plan",
        body: "Local-only canary details",
        tags: ["confidential"],
        source: SourceAnchor(fileURL: localSource)
    )
    let shared = KnowledgeEntity(
        id: EntityID(rawValue: "shared"),
        kind: .note,
        title: "Public launch plan",
        body: "Local-only canary details",
        source: SourceAnchor(fileURL: publicSource)
    )
    _ = try await catalog.replaceEntities(
        from: localSource,
        with: [local],
        includeInPermanentIndex: false
    )
    _ = await catalog.replaceEntities(from: publicSource, with: [shared])

    let results = try await CatalogEntitySearch(catalog: catalog).search(
        "local-only canary",
        limit: 10
    )

    #expect(results.map(\.entityID) == [local.id])
    #expect(results.first?.sourceURL == localSource)
    #expect(try await catalog.permanentlyIndexedEntities().map(\.id) == [shared.id])
}

@Test
func mergedSearchInterleavesFullResultSetsWithoutChangingBackendRanking() async throws {
    let spotlight = StubEntitySearch(results: [
        EntitySearchResult(id: "spotlight:one", title: "Spotlight one"),
        EntitySearchResult(id: "spotlight:two", title: "Spotlight two"),
        EntitySearchResult(id: "spotlight:three", title: "Spotlight three")
    ])
    let local = StubEntitySearch(results: [
        EntitySearchResult(id: "local:one", title: "Local one"),
        EntitySearchResult(id: "local:two", title: "Local two")
    ])

    let results = try await MergedEntitySearch(
        searches: [spotlight, local]
    ).search("plan", limit: 3)

    #expect(
        results.map(\.id)
            == ["spotlight:one", "local:one", "spotlight:two"]
    )
}

@Test
func mergedSearchDeduplicatesCanonicalEntitiesAndSurvivesOneFailedBackend() async throws {
    let entityID = EntityID(rawValue: "shared")
    let local = StubEntitySearch(results: [
        EntitySearchResult(
            id: "catalog:shared",
            entityID: entityID,
            title: "Shared"
        )
    ])
    let duplicateAndExtra = StubEntitySearch(results: [
        EntitySearchResult(
            id: "spotlight:shared",
            entityID: entityID,
            title: "Shared"
        ),
        EntitySearchResult(id: "spotlight:extra", title: "Extra")
    ])
    let merged = MergedEntitySearch(
        searches: [FailingEntitySearch(), local, duplicateAndExtra]
    )

    let results = try await merged.search("shared", limit: 10)

    #expect(results.map(\.id) == ["catalog:shared", "spotlight:extra"])
}

@Test
func liveContextReranksMatchesWithoutDisturbingEqualScoreOrder() {
    let firstID = EntityID(rawValue: "first")
    let visibleID = EntityID(rawValue: "visible")
    let openID = EntityID(rawValue: "open")
    let source = URL(fileURLWithPath: "/notes/Context.md")
    let results = [
        EntitySearchResult(id: "first", entityID: firstID, title: "First"),
        EntitySearchResult(id: "open", entityID: openID, title: "Open"),
        EntitySearchResult(id: "visible", entityID: visibleID, title: "Visible"),
        EntitySearchResult(id: "no-entity", title: "No entity")
    ]
    let context = CurrentContext(
        resolved: [
            ResolvedContextItem(
                entity: KnowledgeEntity(
                    id: visibleID,
                    kind: .note,
                    title: "Visible",
                    source: SourceAnchor(fileURL: source)
                ),
                signals: [],
                score: 110
            ),
            ResolvedContextItem(
                entity: KnowledgeEntity(
                    id: openID,
                    kind: .note,
                    title: "Open",
                    source: SourceAnchor(fileURL: source)
                ),
                signals: [],
                score: 80
            )
        ],
        unresolved: []
    )

    let reranked = ContextualSearchReranker().rerank(results, using: context)

    #expect(reranked.map(\.id) == ["visible", "open", "first", "no-entity"])
}

private struct StubEntitySearch: EntitySearch {
    var results: [EntitySearchResult]

    func search(_ text: String, limit: Int) -> [EntitySearchResult] {
        Array(results.prefix(limit))
    }
}

private struct SearchFailure: Error {}

private struct FailingEntitySearch: EntitySearch {
    func search(_ text: String, limit: Int) throws -> [EntitySearchResult] {
        throw SearchFailure()
    }
}

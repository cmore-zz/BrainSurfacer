import BrainSurfacerCore
import BrainSurfacerModel
import Foundation
import Testing

@Test
func deepLinksRoundTripCanonicalIdentifiersAndSearchTerms() throws {
    let identifier = EntityID(
        rawValue: "org-id:plan/launch?phase=two & owner=🧠"
    )
    let entityLink = BrainSurfacerDeepLink.entity(identifier)
    let searchLink = BrainSurfacerDeepLink.search("release notes & canary")

    #expect(BrainSurfacerDeepLink(url: entityLink.url) == entityLink)
    #expect(BrainSurfacerDeepLink(url: searchLink.url) == searchLink)
    #expect(BrainSurfacerDeepLink(url: URL(string: "https://example.com")!) == nil)
}

@Test
func openingResolvesCanonicalEntityAndFallsBackAfterAnOpenerFailure() async throws {
    let source = URL(fileURLWithPath: "/tmp/Open.md")
    let entity = KnowledgeEntity(
        id: EntityID(rawValue: "open-me"),
        kind: .heading,
        title: "Open me",
        source: SourceAnchor(fileURL: source, headingPath: ["Open me"], line: 8)
    )
    let catalog = InMemoryEntityCatalog()
    _ = await catalog.replaceEntities(from: source, with: [entity])
    let failing = RecordingDocumentOpener(id: "preferred", shouldFail: true)
    let fallback = RecordingDocumentOpener(id: "fallback")
    let coordinator = EntityOpeningCoordinator(
        catalog: catalog,
        openers: [failing, fallback]
    )

    let opened = try await coordinator.open(.entityID(entity.id))

    #expect(opened == entity)
    #expect(await failing.openedIdentifiers == [entity.id])
    #expect(await fallback.openedIdentifiers == [entity.id])
}

@Test
func openingReportsMissingEntitiesAndUnsupportedSources() async throws {
    let source = URL(fileURLWithPath: "/tmp/Unsupported.md")
    let entity = KnowledgeEntity(
        id: EntityID(rawValue: "unsupported"),
        kind: .heading,
        title: "Unsupported",
        source: SourceAnchor(fileURL: source)
    )
    let catalog = InMemoryEntityCatalog()
    _ = await catalog.replaceEntities(from: source, with: [entity])
    let unavailable = RecordingDocumentOpener(id: "unavailable", isAvailable: false)
    let coordinator = EntityOpeningCoordinator(catalog: catalog, openers: [unavailable])

    await #expect(throws: EntityOpeningError.entityNotFound) {
        try await coordinator.open(.entityID(EntityID(rawValue: "missing")))
    }
    await #expect(throws: EntityOpeningError.noCompatibleOpener(source)) {
        try await coordinator.open(.entityID(entity.id))
    }
}

private struct OpeningFailure: LocalizedError, Sendable {
    var errorDescription: String? { "preferred editor failed" }
}

private actor RecordingDocumentOpener: DocumentOpener {
    let id: String
    let shouldFail: Bool
    let isAvailable: Bool
    private(set) var openedIdentifiers: [EntityID] = []

    init(
        id: String,
        shouldFail: Bool = false,
        isAvailable: Bool = true
    ) {
        self.id = id
        self.shouldFail = shouldFail
        self.isAvailable = isAvailable
    }

    func canOpen(_ entity: KnowledgeEntity) async -> Bool {
        isAvailable
    }

    func open(_ entity: KnowledgeEntity) async throws {
        openedIdentifiers.append(entity.id)
        if shouldFail {
            throw OpeningFailure()
        }
    }
}

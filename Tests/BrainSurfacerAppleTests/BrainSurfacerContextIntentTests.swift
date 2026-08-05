@testable import BrainSurfacerApple
import BrainSurfacerCore
import BrainSurfacerModel
import Foundation
import Testing

@Test
func currentContextIntentProjectsExpiringDocumentsWithContentAndSource() async throws {
    let fixture = IntentContextFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 30_000)
    let sourceURL = URL(fileURLWithPath: "/Notes/Current.org")
    let entity = KnowledgeEntity(
        id: EntityID(rawValue: "current-note"),
        kind: .note,
        title: "Current note",
        body: "The content Siri should receive.",
        source: SourceAnchor(fileURL: sourceURL)
    )
    let catalog = PersistentEntityCatalog(
        storageURL: fixture.catalogURL,
        accessMode: .coordinatingWriter
    )
    _ = try await catalog.replaceEntities(from: sourceURL, with: [entity])
    let store = PersistentContextSnapshotStore(storageURL: fixture.contextURL)
    try await store.replace(
        ContextSnapshot(
            providerID: "org.gnu.Emacs",
            observedAt: now,
            contributions: [
                ContextContribution(
                    reference: .file(sourceURL),
                    relevance: .visible,
                    expiresAt: now.addingTimeInterval(60)
                )
            ]
        ),
        at: now
    )

    let entities = try await BrainSurfacerIntentContext.entities(
        at: now,
        snapshotStore: store,
        catalog: catalog
    )

    #expect(entities.count == 1)
    #expect(entities[0].title == "Current note")
    #expect(entities[0].contentExcerpt == "The content Siri should receive.")
    #expect(entities[0].sourceURL == sourceURL)
    #expect(entities[0].relevance == "visible")
    #expect(entities[0].providerIDs == ["org.gnu.Emacs"])

    #expect(
        try await BrainSurfacerIntentContext.entities(
            at: now.addingTimeInterval(60),
            snapshotStore: store,
            catalog: catalog
        ).isEmpty
    )
}

@Test
func noteIntentDetailsIncludeContentAndSourceWithoutUnboundedOutput() {
    let sourceURL = URL(fileURLWithPath: "/Notes/Long.md")
    let note = SpotlightNoteEntity(
        KnowledgeEntity(
            id: EntityID(rawValue: "long-note"),
            kind: .note,
            title: "Long note",
            body: String(
                repeating: "x",
                count: BrainSurfacerIntentText.maximumReturnedNoteCharacters + 1
            ),
            source: SourceAnchor(fileURL: sourceURL)
        )
    )

    let details = BrainSurfacerIntentText.noteDetails(for: note)

    #expect(details.hasPrefix("Long note\nSource: /Notes/Long.md\n\n"))
    #expect(details.hasSuffix("…"))
}

private struct IntentContextFixture {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("BrainSurfacerIntentContextTests-\(UUID().uuidString)")

    var catalogURL: URL {
        directoryURL.appendingPathComponent("catalog.json")
    }

    var contextURL: URL {
        directoryURL.appendingPathComponent("context.json")
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

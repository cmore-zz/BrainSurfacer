import BrainSurfacerCore
import BrainSurfacerModel
import Foundation
import Testing

@Test
func editorContextLinksRoundTripBoundedExpiringSourceAnchors() throws {
    let observedAt = Date(timeIntervalSince1970: 10_000)
    let source = URL(fileURLWithPath: "/notes/Plan.md")
    let update = try EditorContextUpdate(
        providerID: "org.gnu.Emacs",
        observedAt: observedAt,
        timeToLive: 90,
        documents: [
            EditorContextDocument(
                anchor: SourceAnchor(
                    fileURL: source,
                    headingPath: ["Launch"],
                    line: 12
                ),
                relevance: .visible
            ),
            EditorContextDocument(
                fileURL: URL(fileURLWithPath: "/notes/Reference.org"),
                relevance: .open
            )
        ]
    )

    let link = BrainSurfacerDeepLink.context(update)
    let decoded = try #require(BrainSurfacerDeepLink(url: link.url))
    let decodedUpdate: EditorContextUpdate
    guard case let .context(value) = decoded else {
        Issue.record("Expected an editor-context link")
        return
    }
    decodedUpdate = value
    let snapshot = try decodedUpdate.contextSnapshot(
        receivedAt: observedAt.addingTimeInterval(1)
    )

    #expect(decodedUpdate == update)
    #expect(snapshot.providerID == "org.gnu.Emacs")
    #expect(snapshot.contributions.count == 2)
    #expect(snapshot.contributions.map(\.relevance) == [.visible, .open])
    #expect(
        snapshot.contributions.map(\.expiresAt)
            == Array(repeating: observedAt.addingTimeInterval(90), count: 2)
    )
}

@Test
func editorContextRejectsExpiredFutureAndUnsupportedSnapshots() throws {
    let observedAt = Date(timeIntervalSince1970: 20_000)
    let update = try EditorContextUpdate(
        providerID: "md.obsidian",
        observedAt: observedAt,
        timeToLive: 30,
        documents: []
    )

    #expect(throws: EditorContextUpdate.Error.stale) {
        try update.contextSnapshot(
            receivedAt: observedAt.addingTimeInterval(30)
        )
    }
    #expect(throws: EditorContextUpdate.Error.observedInFuture) {
        try update.contextSnapshot(
            receivedAt: observedAt.addingTimeInterval(-31)
        )
    }

    let encoded = try JSONEncoder().encode(update)
    var object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object["version"] = EditorContextUpdate.currentVersion + 1
    let futureData = try JSONSerialization.data(withJSONObject: object)
    #expect(
        throws: EditorContextUpdate.Error.unsupportedVersion(
            EditorContextUpdate.currentVersion + 1
        )
    ) {
        try JSONDecoder().decode(EditorContextUpdate.self, from: futureData)
    }
}

@Test
func editorContextRejectsNonFileURLsAndExcessiveLifetimes() {
    #expect(throws: EditorContextUpdate.Error.invalidDocumentURL) {
        try EditorContextUpdate(
            providerID: "test.provider",
            documents: [
                EditorContextDocument(
                    fileURL: URL(string: "https://example.com/Plan.md")!,
                    relevance: .visible
                )
            ]
        )
    }
    #expect(throws: EditorContextUpdate.Error.invalidTimeToLive) {
        try EditorContextUpdate(
            providerID: "test.provider",
            timeToLive: EditorContextUpdate.maximumTimeToLive + 1,
            documents: []
        )
    }
}

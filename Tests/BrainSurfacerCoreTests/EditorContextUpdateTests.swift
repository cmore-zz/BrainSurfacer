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

@Test
func editorContextJSONInputGroupsLargeWorkingSetsAndResolvesRelativePaths() throws {
    let openDocuments = (0..<60).map { "notes/note-\($0).md" }
    let input = EditorContextInput(
        providerID: "org.gnu.Emacs",
        timeToLive: 120,
        selected: ["selected.org"],
        visible: ["visible.md"],
        open: openDocuments
    )
    let data = try JSONEncoder().encode(input)
    let decoded = try JSONDecoder().decode(EditorContextInput.self, from: data)
    let observedAt = Date(timeIntervalSince1970: 30_000)
    let update = try decoded.update(
        relativeTo: URL(fileURLWithPath: "/Users/test/context", isDirectory: true),
        observedAt: observedAt
    )

    #expect(update.providerID == "org.gnu.Emacs")
    #expect(update.observedAt == observedAt)
    #expect(update.timeToLive == 120)
    #expect(update.documents.count == 62)
    #expect(update.documents[0].relevance == .selected)
    #expect(update.documents[0].anchor.fileURL.path == "/Users/test/context/selected.org")
    #expect(update.documents[1].relevance == .visible)
    #expect(update.documents[2].relevance == .open)
    #expect(
        update.documents.last?.anchor.fileURL.path
            == "/Users/test/context/notes/note-59.md"
    )
}

@Test
func editorContextJSONInputDefaultsOptionalGroupsAndLifetime() throws {
    let data = Data(#"{"providerID":"md.obsidian","open":["Plan.md"]}"#.utf8)
    let input = try EditorContextInput.decodeJSON(data)
    let update = try input.update(
        relativeTo: URL(fileURLWithPath: "/notes", isDirectory: true)
    )

    #expect(input.selected.isEmpty)
    #expect(input.visible.isEmpty)
    #expect(update.timeToLive == EditorContextUpdate.defaultTimeToLive)
    #expect(update.documents.map(\.relevance) == [.open])
}

@Test
func editorContextJSONInputRejectsEmptyPathsAndOversizedFiles() throws {
    let input = EditorContextInput(
        providerID: "test.provider",
        visible: [""]
    )
    #expect(throws: EditorContextInput.Error.emptyPath) {
        try input.update(
            relativeTo: URL(fileURLWithPath: "/notes", isDirectory: true)
        )
    }

    let oversized = Data(
        repeating: 0x20,
        count: EditorContextInput.maximumJSONBytes + 1
    )
    #expect(throws: EditorContextInput.Error.payloadTooLarge) {
        try EditorContextInput.decodeJSON(oversized)
    }
}

@Test
func contextMessagePortTargetsOneRunningProcessWithoutLaunchServices() throws {
    let processIdentifier = ProcessInfo.processInfo.processIdentifier
    #expect(
        ContextMessagePortEndpoint.name(processIdentifier: processIdentifier)
            == "group.org.brainsurfacer.BrainSurfacer.context.\(processIdentifier)"
    )

    let update = try EditorContextUpdate(
        providerID: "test.message-port",
        documents: [
            EditorContextDocument(
                fileURL: URL(fileURLWithPath: "/notes/Plan.md"),
                relevance: .selected
            )
        ]
    )
    let server = try ContextMessagePortServer(
        processIdentifier: processIdentifier
    ) { _ in }

    try ContextMessagePortClient().send(
        update,
        to: processIdentifier
    )
    withExtendedLifetime(server) {}
}

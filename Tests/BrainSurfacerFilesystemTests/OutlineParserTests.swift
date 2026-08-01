import BrainSurfacerFilesystem
import BrainSurfacerModel
import Foundation
import Testing

@Test
func orgOutlineBecomesRelatedSemanticEntities() {
    let source = URL(fileURLWithPath: "/tmp/Projects.org")
    let document = SourceDocument(
        fileURL: source,
        format: .org,
        contents: """
        * BrainSurfacer :swift:macos:
        ** TODO App Intents
        ** Spotlight
        ** Plugins
        """
    )

    let entities = OutlineParser().parse(document)

    #expect(entities.count == 5)
    #expect(entities[0].kind == .note)
    #expect(entities[1].title == "BrainSurfacer")
    #expect(entities[1].tags == ["swift", "macos"])
    #expect(entities[2].kind == .task)
    #expect(entities[2].attributes["taskState"] == "TODO")
    #expect(entities[2].relationships.contains(
        Relationship(kind: .parent, target: entities[1].id)
    ))
}

@Test
func markdownHeadingHierarchyIsPreserved() {
    let source = URL(fileURLWithPath: "/tmp/Architecture.md")
    let document = SourceDocument(
        fileURL: source,
        format: .markdown,
        contents: """
        # Architecture
        ## Filesystem
        ## Semantic model
        """
    )

    let entities = OutlineParser().parse(document)

    #expect(entities.map(\.title) == [
        "Architecture", "Architecture", "Filesystem", "Semantic model"
    ])
    #expect(entities[2].source.headingPath == ["Architecture", "Filesystem"])
    #expect(entities[3].relationships.first?.target == entities[1].id)
}

@Test
func classicMacLineEndingsDoNotTurnTheDocumentIntoOneHeading() {
    let source = URL(fileURLWithPath: "/tmp/Guide.md")
    let document = SourceDocument(
        fileURL: source,
        format: .markdown,
        contents: "# Guide\r\rFirst paragraph.\r\r## Details\rMore text."
    )

    let entities = OutlineParser().parse(document)

    #expect(entities.map(\.title) == ["Guide", "Guide", "Details"])
    #expect(entities[1].source.line == 1)
    #expect(entities[2].source.line == 5)
    #expect(sourceText(for: entities[2].source, in: document) == "## Details\rMore text.")
}

@Test
func orgIdentifiersArePreferredAndRetainedAsEditorAnchors() {
    let source = URL(fileURLWithPath: "/tmp/Identity.org")
    let document = SourceDocument(
        fileURL: source,
        format: .org,
        contents: """
        * Globally identified
        :PROPERTIES:
        :ID: 5E427B36-80D7-4E5F-B71F-94A2A270D559
        :END:
        * Locally identified
        :PROPERTIES:
        :CUSTOM_ID: release-plan
        :END:
        """
    )

    let entities = OutlineParser().parse(document)

    #expect(entities[1].id.rawValue == "org-id:5e427b36-80d7-4e5f-b71f-94a2a270d559")
    #expect(entities[1].source.editorIdentifier == "5E427B36-80D7-4E5F-B71F-94A2A270D559")
    #expect(
        entities[2].attributes[EntityIdentityMetadata.explicitIdentifier]
            == "org-custom-id:release-plan"
    )
    #expect(entities[2].source.editorIdentifier == "release-plan")
}

@Test
func markdownExplicitIdentifiersAreRemovedFromDisplayTitles() {
    let source = URL(fileURLWithPath: "/tmp/Identity.md")
    let document = SourceDocument(
        fileURL: source,
        format: .markdown,
        contents: """
        # Block address ^launch-plan
        ## Attribute address {#details}
        """
    )

    let entities = OutlineParser().parse(document)

    #expect(entities[1].title == "Block address")
    #expect(entities[1].source.editorIdentifier == "launch-plan")
    #expect(
        entities[1].attributes[EntityIdentityMetadata.explicitIdentifier]
            == "markdown-id:launch-plan"
    )
    #expect(entities[2].title == "Attribute address")
    #expect(entities[2].source.editorIdentifier == "details")
}

@Test
func markdownSectionsRetainDirectContentAndPreciseSubtreeAnchors() throws {
    let document = try fixture(named: "section-content", extension: "md", format: .markdown)

    let entities = OutlineParser().parse(document)
    let note = try #require(entities.first)
    let launch = try #require(entities.first { $0.title == "Launch plan" })
    let constraints = try #require(entities.first { $0.title == "Constraints" })

    #expect(note.tags == ["architecture", "swift"])
    #expect(note.dates == [KnowledgeDate(kind: .mentioned, rawValue: "2026-07-30")])
    #expect(launch.body == """
        Ship the semantic indexing slice with a [design note](https://example.com/design).
        Keep the rollout reversible.
        """)
    #expect(launch.summary == "Ship the semantic indexing slice with a design note.")
    #expect(launch.links == [URL(string: "https://example.com/design")!])
    #expect(launch.relationships.contains(Relationship(kind: .parent, target: note.id)))
    #expect(constraints.relationships.contains(Relationship(kind: .belongsTo, target: note.id)))
    #expect(launch.source.line == 6)
    #expect(launch.source.endLine == 14)
    #expect(sourceText(for: launch.source, in: document).contains("Child prose"))
    #expect(!sourceText(for: launch.source, in: document).contains("# Follow-up"))
}

@Test
func orgSectionsRetainPlanningDatesWithoutIndexingDrawers() throws {
    let document = try fixture(named: "section-content", extension: "org", format: .org)

    let entities = OutlineParser().parse(document)
    let note = try #require(entities.first)
    let release = try #require(entities.first { $0.title == "Release" })
    let verification = try #require(entities.first { $0.title == "Verification" })

    #expect(note.title == "Release Notes")
    #expect(note.tags == ["org", "planning"])
    #expect(release.id.rawValue == "org-id:72a90d5b-f22f-46b2-8df4-85fae69947c0")
    #expect(release.body == "Coordinate the release using [[https://example.com/runbook][the runbook]].")
    #expect(release.summary == "Coordinate the release using the runbook.")
    #expect(release.links == [URL(string: "https://example.com/runbook")!])
    #expect(release.dates == [
        KnowledgeDate(kind: .scheduled, rawValue: "2026-08-03 Mon"),
        KnowledgeDate(kind: .deadline, rawValue: "2026-08-07 Fri")
    ])
    #expect(verification.relationships.contains(Relationship(kind: .belongsTo, target: note.id)))
    #expect(!release.body!.contains(":PROPERTIES:"))
    #expect(!release.body!.contains("Child verification"))
}

@Test
func sectionBodiesAreUTF8SafelyBoundedAndDeepHeadingsAreIgnored() throws {
    let oversizedBody = String(repeating: "🧠", count: 20_000)
    let deepHeading = String(repeating: "*", count: OutlineParser.maximumHeadingDepth + 1)
    let document = SourceDocument(
        fileURL: URL(fileURLWithPath: "/tmp/Bounds.org"),
        format: .org,
        contents: "* Bounded\n\(oversizedBody)\n\(deepHeading) Too deep"
    )

    let entities = OutlineParser().parse(document)
    let bounded = try #require(entities.first { $0.title == "Bounded" })

    #expect(bounded.body!.utf8.count <= OutlineParser.maximumSectionBodyBytes)
    #expect(String(data: Data(bounded.body!.utf8), encoding: .utf8) != nil)
    #expect(bounded.attributes["bodyTruncated"] == "true")
    #expect(!entities.contains { $0.title == "Too deep" })
}

@Test
func entitiesFromOlderCatalogsDecodeWithEmptyDateMetadata() throws {
    let current = KnowledgeEntity(
        id: EntityID(rawValue: "legacy"),
        kind: .heading,
        title: "Legacy",
        source: SourceAnchor(fileURL: URL(fileURLWithPath: "/tmp/Legacy.md"))
    )
    let encoded = try JSONEncoder().encode(current)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "dates")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(KnowledgeEntity.self, from: legacyData)

    #expect(decoded.dates.isEmpty)
}

private func fixture(
    named name: String,
    extension pathExtension: String,
    format: SourceDocument.Format
) throws -> SourceDocument {
    let url = try #require(
        Bundle.module.url(
            forResource: name,
            withExtension: pathExtension,
            subdirectory: "Fixtures"
        )
    )
    return SourceDocument(
        fileURL: URL(fileURLWithPath: "/tmp/\(name).\(pathExtension)"),
        format: format,
        contents: try String(contentsOf: url, encoding: .utf8)
    )
}

private func sourceText(for anchor: SourceAnchor, in document: SourceDocument) -> String {
    guard let offset = anchor.byteOffset, let length = anchor.byteLength else {
        return ""
    }
    let bytes = Array(document.contents.utf8)
    return String(decoding: bytes[offset ..< offset + length], as: UTF8.self)
}

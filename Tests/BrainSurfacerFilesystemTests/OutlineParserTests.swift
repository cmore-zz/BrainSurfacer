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
    #expect(entities[2].relationships == [
        Relationship(kind: .parent, target: entities[1].id)
    ])
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

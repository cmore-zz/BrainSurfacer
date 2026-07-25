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

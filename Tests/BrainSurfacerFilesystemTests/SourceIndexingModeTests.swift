@testable import BrainSurfacerFilesystem
import BrainSurfacerModel
import Foundation
import Testing

@Test
func unknownFutureIndexingModesFailClosedToPaused() throws {
    let data = try #require("\"future-private-mode\"".data(using: .utf8))
    let mode = try JSONDecoder().decode(SourceIndexingMode.self, from: data)

    #expect(mode == .paused)
}

@Test
func metadataOnlyRemovesContentWhileRetainingStructuralMetadata() {
    let parentID = EntityID(rawValue: "parent")
    let linkedID = EntityID(rawValue: "linked")
    let source = SourceAnchor(
        fileURL: URL(fileURLWithPath: "/notes/Plan.md"),
        headingPath: ["Plan"],
        line: 1,
        byteOffset: 0,
        byteLength: 42
    )
    let entity = KnowledgeEntity(
        id: EntityID(rawValue: "plan"),
        kind: .heading,
        title: "Plan",
        body: "Private details",
        summary: "Private summary",
        tags: ["work"],
        links: [URL(string: "https://example.com/private")!],
        dates: [KnowledgeDate(kind: .mentioned, rawValue: "2026-08-04")],
        relationships: [
            Relationship(kind: .parent, target: parentID),
            Relationship(kind: .linksTo, target: linkedID)
        ],
        source: source,
        attributes: [
            "bodyTruncated": "true",
            "taskState": "TODO",
            "futureExcerpt": "Private future content",
            EntityIdentityMetadata.observedIdentifier: "observed-id",
            EntityIdentityMetadata.explicitIdentifier: "explicit-id",
            EntityIdentityMetadata.structuralFingerprint: "structural-id"
        ]
    )

    let projected = SourceIndexingMode.metadataOnly.applying(to: [entity])[0]

    #expect(projected.body == nil)
    #expect(projected.summary == nil)
    #expect(projected.links.isEmpty)
    #expect(projected.tags == ["work"])
    #expect(projected.dates == entity.dates)
    #expect(projected.source == source)
    #expect(projected.relationships == [
        Relationship(kind: .parent, target: parentID)
    ])
    #expect(projected.attributes == [
        "taskState": "TODO",
        EntityIdentityMetadata.observedIdentifier: "observed-id",
        EntityIdentityMetadata.explicitIdentifier: "explicit-id",
        EntityIdentityMetadata.structuralFingerprint: "structural-id"
    ])
}

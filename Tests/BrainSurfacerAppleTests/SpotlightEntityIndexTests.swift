@testable import BrainSurfacerApple
import BrainSurfacerModel
import CoreSpotlight
import Foundation
import Testing

@Test
func oversizedCanonicalIdentifierProjectsToBoundedStableSpotlightIdentifier() {
    let canonicalID = EntityID(rawValue: "outline:" + String(repeating: "knowledge", count: 1_000))
    let entity = KnowledgeEntity(
        id: canonicalID,
        kind: .heading,
        title: "Long document",
        source: SourceAnchor(fileURL: URL(fileURLWithPath: "/tmp/Long.md"))
    )

    let firstProjection = SpotlightKnowledgeEntity(entity)
    let secondProjection = SpotlightKnowledgeEntity(entity)
    let searchableItem = CSSearchableItem(appEntity: firstProjection)

    #expect(firstProjection.id == secondProjection.id)
    #expect(firstProjection.id.hasPrefix("sha256:"))
    #expect(firstProjection.id.utf8.count == 71)
    #expect(searchableItem.uniqueIdentifier.utf8.count <= 4_096)
}

@Test
func ordinaryCanonicalIdentifierIsPreservedBySpotlightProjection() {
    let canonicalID = EntityID(rawValue: "outline:/notes/project.md::next action")

    #expect(SpotlightKnowledgeEntity.indexIdentifier(for: canonicalID) == canonicalID.rawValue)
}

@Test
func spotlightErrorDescriptionExplainsInvalidMetadata() {
    let error = SpotlightIndexingError(code: -1001)

    #expect(error.errorDescription?.contains("metadata was invalid") == true)
    #expect(error.errorDescription?.contains("-1001") == true)
}

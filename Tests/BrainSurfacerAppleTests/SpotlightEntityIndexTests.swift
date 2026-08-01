@testable import BrainSurfacerApple
import BrainSurfacerCore
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
func customProjectionSeparatesSearchableBodyFromDisplaySummary() {
    let entity = KnowledgeEntity(
        id: EntityID(rawValue: "section"),
        kind: .heading,
        title: "Section",
        body: "The complete searchable section body contains a canary phrase.",
        summary: "A short display summary.",
        source: SourceAnchor(fileURL: URL(fileURLWithPath: "/tmp/Section.md"))
    )

    let projection = SpotlightKnowledgeEntity(entity)

    #expect(projection.text == entity.body)
    #expect(projection.summary == entity.summary)
    #expect(projection.attributeSet.textContent == entity.body)
    #expect(projection.attributeSet.contentDescription == entity.summary)
}

@Test
func spotlightErrorDescriptionExplainsInvalidMetadata() {
    let error = SpotlightIndexingError(code: -1001)

    #expect(error.errorDescription?.contains("metadata was invalid") == true)
    #expect(error.errorDescription?.contains("-1001") == true)
}

@Test
func noteProjectionUsesNotesSchemaAndItsOwnSearchDomain() {
    let modifiedAt = Date(timeIntervalSince1970: 1_725_000_000)
    let entity = KnowledgeEntity(
        id: EntityID(rawValue: "note"),
        kind: .note,
        title: "Note",
        body: "Searchable text",
        summary: "Short note summary",
        tags: ["swift", "Work"],
        source: SourceAnchor(fileURL: URL(fileURLWithPath: "/tmp/Notes/Note.md")),
        modifiedAt: modifiedAt,
        attributes: ["isPinned": "true"]
    )

    let projection = SpotlightNoteEntity(entity)
    let searchableItem = CSSearchableItem(appEntity: projection)

    #expect(String(projection.name.characters) == "Note")
    #expect(projection.content.map { String($0.characters) } == "Searchable text")
    #expect(projection.tags.map(\.name) == ["Work", "swift"])
    #expect(projection.isPinned)
    #expect(projection.modificationDate == modifiedAt)
    #expect(projection.folder?.name == "Notes")
    #expect(projection.attributeSet.textContent == "Searchable text")
    #expect(projection.attributeSet.contentDescription == "Short note summary")
    #expect(searchableItem.domainIdentifier == SpotlightNoteEntity.searchDomainIdentifier)
}

@Test
func spotlightSearchResultPreservesDisplayMetadata() {
    let attributes = CSSearchableItemAttributeSet()
    attributes.title = "Search result"
    attributes.contentDescription = "A short excerpt"
    attributes.contentURL = URL(fileURLWithPath: "/tmp/Result.md")
    let item = CSSearchableItem(
        uniqueIdentifier: "result-id",
        domainIdentifier: SpotlightKnowledgeEntity.searchDomainIdentifier,
        attributeSet: attributes
    )

    let result = SpotlightEntitySearch.result(from: item)

    #expect(result.id == "result-id")
    #expect(result.title == "Search result")
    #expect(result.summary == "A short excerpt")
    #expect(result.sourceURL == URL(fileURLWithPath: "/tmp/Result.md"))
}

@Test
func spotlightEntityQueriesResolveOnlyTheirProjectionKinds() async throws {
    let source = URL(fileURLWithPath: "/notes/query.md")
    let ordinary = KnowledgeEntity(
        id: EntityID(rawValue: "ordinary"),
        kind: .note,
        title: "Ordinary",
        source: SourceAnchor(fileURL: source)
    )
    let oversized = KnowledgeEntity(
        id: EntityID(rawValue: String(repeating: "long", count: 600)),
        kind: .heading,
        title: "Oversized",
        source: SourceAnchor(fileURL: source)
    )
    let catalog = InMemoryEntityCatalog()
    _ = await catalog.replaceEntities(from: source, with: [ordinary, oversized])
    let ordinaryID = SpotlightKnowledgeEntity.indexIdentifier(for: ordinary.id)
    let oversizedID = SpotlightKnowledgeEntity.indexIdentifier(for: oversized.id)
    let customQuery = SpotlightKnowledgeEntity.Query(catalog: catalog)
    let noteQuery = SpotlightNoteEntity.Query(catalog: catalog)

    let customEntities = try await customQuery.entities(
        for: [oversizedID, "missing", ordinaryID]
    )
    let noteEntities = try await noteQuery.entities(
        for: [oversizedID, "missing", ordinaryID]
    )

    #expect(customEntities.map(\.id) == [oversizedID])
    #expect(noteEntities.map(\.id) == [ordinaryID])
}

@Test
func taskProjectionRemainsCustomUntilReminderSemanticsExist() {
    let task = KnowledgeEntity(
        id: EntityID(rawValue: "task"),
        kind: .task,
        title: "Ship slice three",
        source: SourceAnchor(fileURL: URL(fileURLWithPath: "/tmp/Plan.org")),
        attributes: ["taskState": "TODO"]
    )

    #expect(SpotlightProjection.kind(for: task) == .custom)
    #expect(SpotlightKnowledgeEntity(task).subtitle == "Task")
}

@Test
func nestedTagAndFolderQueriesResolveFromTheCatalog() async throws {
    let source = URL(fileURLWithPath: "/notes/Projects/Plan.md")
    let note = KnowledgeEntity(
        id: EntityID(rawValue: "note"),
        kind: .note,
        title: "Plan",
        tags: ["swift", "architecture"],
        source: SourceAnchor(fileURL: source)
    )
    let catalog = InMemoryEntityCatalog()
    _ = await catalog.replaceEntities(from: source, with: [note])
    let swiftTag = SpotlightNoteTagEntity(name: "swift")
    let folder = SpotlightNoteFolderEntity(
        directoryURL: source.deletingLastPathComponent()
    )

    let tags = try await SpotlightNoteTagEntity.Query(catalog: catalog).entities(
        for: [swiftTag.id]
    )
    let folders = try await SpotlightNoteFolderEntity.Query(catalog: catalog).entities(
        for: [folder.id]
    )

    #expect(tags.map(\.name) == ["swift"])
    #expect(folders.map(\.name) == ["Projects"])
    #expect(folders.first?.account?.name == "BrainSurfacer Sources")
}

@Test
func projectionVersionIsPersistedForControlledRebuilds() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("BrainSurfacerProjectionTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SpotlightProjectionVersionStore(
        storageURL: directory.appendingPathComponent("version")
    )

    #expect(store.storedVersion() == nil)
    try store.markCurrent(version: SpotlightProjection.schemaVersion)
    #expect(store.storedVersion() == SpotlightProjection.schemaVersion)
}

@Test
func spotlightSearchIncludesCustomAndNotesProjectionDomains() {
    #expect(
        SpotlightEntitySearch.searchDomainFilter.contains(
            SpotlightKnowledgeEntity.searchDomainIdentifier
        )
    )
    #expect(
        SpotlightEntitySearch.searchDomainFilter.contains(
            SpotlightNoteEntity.searchDomainIdentifier
        )
    )
}

@Test
func appIntentQueriesHaveDistinctPersistentIdentifiers() {
    let identifiers = [
        SpotlightKnowledgeEntity.Query.persistentIdentifier,
        SpotlightNoteEntity.Query.persistentIdentifier,
        SpotlightNoteTagEntity.Query.persistentIdentifier,
        SpotlightNoteFolderEntity.Query.persistentIdentifier,
        SpotlightNoteAccountEntity.Query.persistentIdentifier
    ]

    #expect(Set(identifiers).count == identifiers.count)
}

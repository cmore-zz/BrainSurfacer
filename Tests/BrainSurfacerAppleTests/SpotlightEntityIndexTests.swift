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
    #expect(projection.openURL == BrainSurfacerDeepLink.entity(entity.id).url)
    #expect(projection.attributeSet.path == entity.source.fileURL.path)
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
    #expect(projection.openURL == BrainSurfacerDeepLink.entity(entity.id).url)
    #expect(projection.attributeSet.path == entity.source.fileURL.path)
    #expect(searchableItem.domainIdentifier == SpotlightNoteEntity.searchDomainIdentifier)
}

@Test
func spotlightSearchResultPreservesDisplayMetadata() {
    let attributes = CSSearchableItemAttributeSet()
    attributes.title = "Search result"
    attributes.contentDescription = "A short excerpt"
    let entityID = EntityID(rawValue: "canonical-result")
    attributes.contentURL = BrainSurfacerDeepLink.entity(entityID).url
    attributes.path = "/tmp/Result.md"
    let item = CSSearchableItem(
        uniqueIdentifier: "result-id",
        domainIdentifier: SpotlightKnowledgeEntity.searchDomainIdentifier,
        attributeSet: attributes
    )

    let result = SpotlightEntitySearch.result(from: item)

    #expect(result.id == "result-id")
    #expect(result.entityID == entityID)
    #expect(result.title == "Search result")
    #expect(result.summary == "A short excerpt")
    #expect(result.sourceURL == URL(fileURLWithPath: "/tmp/Result.md"))
}

@Test
func spotlightSearchIgnoresAnEmptySourcePath() {
    let fallbackURL = URL(fileURLWithPath: "/tmp/Fallback.md")
    let attributes = CSSearchableItemAttributeSet()
    attributes.title = "Fallback"
    attributes.path = ""
    attributes.contentURL = fallbackURL
    let item = CSSearchableItem(
        uniqueIdentifier: "fallback-id",
        domainIdentifier: SpotlightKnowledgeEntity.searchDomainIdentifier,
        attributeSet: attributes
    )

    let result = SpotlightEntitySearch.result(from: item)

    #expect(result.sourceURL == fallbackURL)
}

@Test
func editorRequestsPreserveTheBestAvailableSourceAnchor() throws {
    let entity = KnowledgeEntity(
        id: EntityID(rawValue: "anchored"),
        kind: .heading,
        title: "Launch Plan",
        source: SourceAnchor(
            fileURL: URL(fileURLWithPath: "/tmp/Project Plan.md"),
            headingPath: ["Project", "Launch Plan"],
            line: 42,
            column: 7
        )
    )

    let obsidianURL = try #require(ConfiguredDocumentOpener.obsidianURL(for: entity))
    let components = try #require(
        URLComponents(url: obsidianURL, resolvingAgainstBaseURL: false)
    )

    #expect(obsidianURL.scheme == "obsidian")
    #expect(
        components.queryItems?.first(where: { $0.name == "path" })?.value
            == "/tmp/Project Plan.md#Launch Plan"
    )
    #expect(
        ConfiguredDocumentOpener.emacsArguments(for: entity)
            == ["+42:7", "/tmp/Project Plan.md"]
    )
}

@Test
func securityScopedAccessSelectsTheMostSpecificEnclosingSource() {
    let broadRoot = URL(fileURLWithPath: "/Users/example/Notes")
    let nestedRoot = URL(fileURLWithPath: "/Users/example/Notes/Projects")
    let lookalikeRoot = URL(fileURLWithPath: "/Users/example/Notebook")
    let document = URL(
        fileURLWithPath: "/Users/example/Notes/Projects/Launch/Plan.md"
    )

    let root = SecurityScopedBookmarkDocumentAccess.enclosingRoot(
        for: document,
        among: [broadRoot, lookalikeRoot, nestedRoot]
    )

    #expect(root == nestedRoot)
    #expect(
        SecurityScopedBookmarkDocumentAccess.enclosingRoot(
            for: URL(fileURLWithPath: "/Users/example/Notes-old/Plan.md"),
            among: [broadRoot]
        ) == nil
    )
}

@Test
func configuredOpenerChecksTheSourceInsideItsAccessLease() async throws {
    let source = URL(
        fileURLWithPath: "/missing/\(UUID().uuidString)/Document.md"
    )
    let entity = KnowledgeEntity(
        id: EntityID(rawValue: "leased"),
        kind: .note,
        title: "Leased",
        source: SourceAnchor(fileURL: source)
    )
    let access = RecordingDocumentAccessProvider()
    let opener = ConfiguredDocumentOpener(accessProvider: access)

    await #expect(throws: DocumentOpeningFailure.self) {
        try await opener.open(entity)
    }
    #expect(await access.requestedURLs == [source])
}

@Test
func sourceValidationDoesNotConfusePermissionDenialWithDeletion() {
    let missing = NSError(
        domain: NSCocoaErrorDomain,
        code: CocoaError.Code.fileReadNoSuchFile.rawValue
    )
    let denied = NSError(
        domain: NSCocoaErrorDomain,
        code: CocoaError.Code.fileReadNoPermission.rawValue
    )

    #expect(ConfiguredDocumentOpener.isMissingSourceError(missing))
    #expect(!ConfiguredDocumentOpener.isMissingSourceError(denied))
}

@Test
func appIntentOpeningDoesNotRepeatASystemPresentedFailure() async throws {
    let source = URL(fileURLWithPath: "/tmp/Intent-Presented.md")
    let entity = KnowledgeEntity(
        id: EntityID(rawValue: "intent-presented"),
        kind: .note,
        title: "Intent presented",
        source: SourceAnchor(fileURL: source)
    )
    let catalog = InMemoryEntityCatalog()
    _ = await catalog.replaceEntities(from: source, with: [entity])
    let opener = IntentPresentedFailingOpener()

    try await BrainSurfacerIntentOpening.open(
        entity.id,
        catalog: catalog,
        openers: [opener]
    )

    #expect(await opener.openCount == 1)
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

private actor RecordingDocumentAccessProvider: DocumentAccessProvider {
    private(set) var requestedURLs: [URL] = []

    func performWithAccess(
        to documentURL: URL,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        requestedURLs.append(documentURL)
        try await operation()
    }
}

private struct IntentPresentedFailure: LocalizedError,
    UserPresentedDocumentOpeningError {
    var errorDescription: String? { "Already presented by macOS" }
}

private actor IntentPresentedFailingOpener: DocumentOpener {
    let id = "intent-presented-failure"
    private(set) var openCount = 0

    func canOpen(_ entity: KnowledgeEntity) async -> Bool { true }

    func open(_ entity: KnowledgeEntity) async throws {
        openCount += 1
        throw IntentPresentedFailure()
    }
}

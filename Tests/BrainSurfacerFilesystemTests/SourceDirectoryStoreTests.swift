@testable import BrainSurfacerFilesystem
import Foundation
import Testing

@Test
func sourceDirectoriesPersistDeduplicateAndCanBeRemoved() async throws {
    let suiteName = "BrainSurfacerTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    let directory = FileManager.default.temporaryDirectory
        .appending(path: "BrainSurfacerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let store = SourceDirectoryStore(
        suiteName: suiteName,
        storageKey: "testSourceDirectoryBookmarks"
    )

    let added = try await store.add([directory, directory])
    let reloaded = await store.load()
    let remaining = await store.remove(try #require(reloaded.first))

    #expect(added == [SourceDirectory(url: directory)])
    #expect(reloaded == added)
    #expect(remaining.isEmpty)
    #expect(await store.load().isEmpty)
}

@Test
func sourceAccessUsesTheConfiguredEnrollmentStore() async throws {
    let suiteName = "BrainSurfacerTests.\(UUID().uuidString)"
    let storageKey = "testSourceAccessBookmarks"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    let directory = FileManager.default.temporaryDirectory
        .appending(path: "BrainSurfacerAccess-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let enrollment = SourceDirectoryStore(
        suiteName: suiteName,
        storageKey: storageKey
    )
    _ = try await enrollment.add([directory])

    let access = SourceDirectoryStore(
        suiteName: suiteName,
        storageKey: storageKey
    )
    let document = directory.appending(path: "Note.md")
    let root = await access.enclosingEnrolledRoot(for: document)
    let recorder = AccessOperationRecorder()
    try await access.performWithAccess(to: document) {
        await recorder.record()
    }

    #expect(root == directory.standardizedFileURL)
    #expect(await recorder.callCount == 1)
}

@Test
func editorContextCandidatesAreLimitedToEnrolledSourceTrees() async throws {
    let suiteName = "BrainSurfacerTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    let directory = FileManager.default.temporaryDirectory
        .appending(
            path: "BrainSurfacerContext-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let store = SourceDirectoryStore(
        suiteName: suiteName,
        storageKey: "testContextEnrollment"
    )
    _ = try await store.add([directory])
    let enrolled = directory.appending(path: "Projects/Plan.md")
    let outside = directory.deletingLastPathComponent()
        .appending(path: "NotEnrolled/Secret.org")
    let lookalike = URL(fileURLWithPath: directory.path + "-old/Plan.md")

    let accepted = await store.enrolledDocumentURLs(
        in: [outside, enrolled, lookalike]
    )

    #expect(accepted == [enrolled.standardizedFileURL])
}

@Test
func editorContextEnrollmentRejectsSymlinksEscapingTheSourceTree() async throws {
    let suiteName = "BrainSurfacerTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    let parent = FileManager.default.temporaryDirectory.appending(
        path: "BrainSurfacerContextSymlink-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    let enrolledDirectory = parent.appending(path: "Enrolled", directoryHint: .isDirectory)
    let outsideDirectory = parent.appending(path: "Outside", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: enrolledDirectory,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: outsideDirectory,
        withIntermediateDirectories: true
    )
    let outsideDocument = outsideDirectory.appending(path: "Secret.org")
    try Data("secret".utf8).write(to: outsideDocument)
    defer {
        try? FileManager.default.removeItem(at: parent)
    }

    let link = enrolledDirectory.appending(path: "escaped", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(
        at: link,
        withDestinationURL: outsideDirectory
    )
    let store = SourceDirectoryStore(
        suiteName: suiteName,
        storageKey: "testContextSymlinkEnrollment"
    )
    _ = try await store.add([enrolledDirectory])

    let accepted = await store.enrolledDocumentURLs(
        in: [link.appending(path: "Secret.org")]
    )

    #expect(accepted.isEmpty)
}

@Test
func sourceConfigurationsPersistWithEnrollmentAndAreRemovedWithIt() async throws {
    let suiteName = "BrainSurfacerTests.\(UUID().uuidString)"
    let storageKey = "testSourcePolicyEnrollments"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    let directory = FileManager.default.temporaryDirectory
        .appending(path: "BrainSurfacerPolicy-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let store = SourceDirectoryStore(suiteName: suiteName, storageKey: storageKey)
    let source = try #require(try await store.add([directory]).first)
    let policy = SourcePathPolicy(
        includePatterns: ["Projects/**"],
        excludePatterns: ["Projects/Archive/**"]
    )
    let overrides = [
        try #require(SourceFormatOverride(suffix: ".forum.txt", format: .bbcode)),
        try #require(SourceFormatOverride(suffix: "notes", target: .automatic))
    ]
    let updated = try #require(
        await store.updateConfiguration(
            pathPolicy: policy,
            indexingMode: .metadataOnly,
            discoveryScope: .localOnly,
            formatOverrides: overrides,
            for: source
        ).first
    )
    let pathOnlyUpdateFromStaleSource = try #require(
        await store.updatePathPolicy(policy, for: source).first
    )
    let modeUpdateFromStaleSource = try #require(
        await store.updateConfiguration(
            pathPolicy: policy,
            indexingMode: .metadataOnly,
            for: source
        ).first
    )
    let relaunched = SourceDirectoryStore(
        suiteName: suiteName,
        storageKey: storageKey
    )

    #expect(updated.pathPolicy == policy)
    #expect(updated.indexingMode == .metadataOnly)
    #expect(updated.discoveryScope == .localOnly)
    #expect(updated.formatOverrides.map(\.suffix) == [".forum.txt", ".notes"])
    #expect(updated.formatOverrides.map(\.target) == [.bbcode, .automatic])
    #expect(pathOnlyUpdateFromStaleSource.indexingMode == .metadataOnly)
    #expect(pathOnlyUpdateFromStaleSource.discoveryScope == .localOnly)
    #expect(pathOnlyUpdateFromStaleSource.formatOverrides == updated.formatOverrides)
    #expect(modeUpdateFromStaleSource.discoveryScope == .localOnly)
    #expect(modeUpdateFromStaleSource.formatOverrides == updated.formatOverrides)
    #expect(await relaunched.load().first?.pathPolicy == policy)
    #expect(await relaunched.load().first?.indexingMode == .metadataOnly)
    #expect(await relaunched.load().first?.discoveryScope == .localOnly)
    #expect(await relaunched.load().first?.formatOverrides == updated.formatOverrides)

    _ = await relaunched.remove(updated)
    let reenrolled = try #require(try await relaunched.add([directory]).first)
    #expect(reenrolled.pathPolicy.isUnrestricted)
    #expect(reenrolled.indexingMode == .fullContent)
    #expect(reenrolled.discoveryScope == .localAndApple)
    #expect(reenrolled.formatOverrides.isEmpty)
}

@Test
func legacyBookmarkArraysMigrateToUnrestrictedEnrollmentRecords() async throws {
    let suiteName = "BrainSurfacerTests.\(UUID().uuidString)"
    let storageKey = "testLegacySourceBookmarks"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    let directory = FileManager.default.temporaryDirectory
        .appending(path: "BrainSurfacerLegacy-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let bookmark = try directory.bookmarkData(
        options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
        includingResourceValuesForKeys: [.isDirectoryKey],
        relativeTo: nil
    )
    defaults.set([bookmark], forKey: storageKey)

    let store = SourceDirectoryStore(suiteName: suiteName, storageKey: storageKey)
    let migrated = try #require(await store.load().first)
    let relaunched = SourceDirectoryStore(
        suiteName: suiteName,
        storageKey: storageKey
    )

    #expect(migrated.url == directory.standardizedFileURL)
    #expect(migrated.pathPolicy.isUnrestricted)
    #expect(migrated.indexingMode == .fullContent)
    #expect(migrated.discoveryScope == .localAndApple)
    #expect(defaults.data(forKey: storageKey) != nil)
    #expect(await relaunched.load() == [migrated])
}

@Test
func decodableFutureEnrollmentSchemasRemainVisibleOnDowngrade() async throws {
    let suiteName = "BrainSurfacerTests.\(UUID().uuidString)"
    let storageKey = "testFutureSourceEnrollments"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    let directory = FileManager.default.temporaryDirectory
        .appending(path: "BrainSurfacerFuture-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let writer = SourceDirectoryStore(suiteName: suiteName, storageKey: storageKey)
    let enrolled = try #require(try await writer.add([directory]).first)
    let storedData = try #require(defaults.data(forKey: storageKey))
    var storedObject = try #require(
        JSONSerialization.jsonObject(with: storedData) as? [String: Any]
    )
    storedObject["schemaVersion"] = 6
    storedObject["futureMetadata"] = ["preservedByNewerWriter": true]
    var futureEnrollments = try #require(
        storedObject["enrollments"] as? [[String: Any]]
    )
    futureEnrollments[0]["formatOverrides"] = [
        ["suffix": ".future", "format": "future-format"]
    ]
    storedObject["enrollments"] = futureEnrollments
    let futureData = try JSONSerialization.data(withJSONObject: storedObject)
    defaults.set(futureData, forKey: storageKey)

    let olderReader = SourceDirectoryStore(
        suiteName: suiteName,
        storageKey: storageKey
    )
    let loaded = await olderReader.load()
    let unchanged = await olderReader.updatePathPolicy(
        enrolled.pathPolicy,
        for: enrolled
    )

    #expect(loaded == [enrolled])
    #expect(loaded.first?.formatOverrides.isEmpty == true)
    #expect(unchanged == [enrolled])
    #expect(defaults.data(forKey: storageKey) == futureData)
}

@Test
func enrollmentRecordsWithoutModesOrScopesUseHistoricalDefaults() async throws {
    let suiteName = "BrainSurfacerTests.\(UUID().uuidString)"
    let storageKey = "testModeMigrationEnrollments"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    let directory = FileManager.default.temporaryDirectory
        .appending(path: "BrainSurfacerModeMigration-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let writer = SourceDirectoryStore(suiteName: suiteName, storageKey: storageKey)
    _ = try await writer.add([directory])
    let storedData = try #require(defaults.data(forKey: storageKey))
    var storedObject = try #require(
        JSONSerialization.jsonObject(with: storedData) as? [String: Any]
    )
    var enrollments = try #require(storedObject["enrollments"] as? [[String: Any]])
    enrollments[0].removeValue(forKey: "indexingMode")
    enrollments[0].removeValue(forKey: "discoveryScope")
    enrollments[0].removeValue(forKey: "formatOverrides")
    storedObject["schemaVersion"] = 1
    storedObject["enrollments"] = enrollments
    defaults.set(
        try JSONSerialization.data(withJSONObject: storedObject),
        forKey: storageKey
    )

    let migrated = SourceDirectoryStore(
        suiteName: suiteName,
        storageKey: storageKey
    )
    let source = try #require(await migrated.load().first)

    #expect(source.indexingMode == .fullContent)
    #expect(source.discoveryScope == .localAndApple)
    #expect(source.pathPolicy.isUnrestricted)
    #expect(source.formatOverrides.isEmpty)
}

@Test
func unknownFutureDiscoveryScopesFailClosedToLocalOnly() throws {
    let data = try #require("\"future-sharing-scope\"".data(using: .utf8))
    let scope = try JSONDecoder().decode(SourceDiscoveryScope.self, from: data)

    #expect(scope == .localOnly)
}

@Test
func sourceAccessSelectsTheMostSpecificEnclosingSource() {
    let broadRoot = URL(fileURLWithPath: "/Users/example/Notes")
    let nestedRoot = URL(fileURLWithPath: "/Users/example/Notes/Projects")
    let lookalikeRoot = URL(fileURLWithPath: "/Users/example/Notebook")
    let document = URL(
        fileURLWithPath: "/Users/example/Notes/Projects/Launch/Plan.md"
    )

    let root = SourceDirectoryStore.enclosingRoot(
        for: document,
        among: [broadRoot, lookalikeRoot, nestedRoot]
    )

    #expect(root == nestedRoot)
    #expect(
        SourceDirectoryStore.enclosingRoot(
            for: URL(fileURLWithPath: "/Users/example/Notes-old/Plan.md"),
            among: [broadRoot]
        ) == nil
    )
}

private actor AccessOperationRecorder {
    private(set) var callCount = 0

    func record() {
        callCount += 1
    }
}

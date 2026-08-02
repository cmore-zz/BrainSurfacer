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

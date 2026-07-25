import BrainSurfacerFilesystem
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

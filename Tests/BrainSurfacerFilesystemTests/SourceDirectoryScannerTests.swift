import BrainSurfacerFilesystem
import Foundation
import Testing

@Test
func scannerRecursivelyParsesSupportedKnowledgeFiles() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "BrainSurfacerScan-\(UUID().uuidString)", directoryHint: .isDirectory)
    let nested = root.appending(path: "Projects", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: nested,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    try """
    # Home
    ## Inbox
    """.write(
        to: root.appending(path: "Home.md"),
        atomically: true,
        encoding: .utf8
    )
    try """
    * BrainSurfacer
    ** TODO Index sources
    """.write(
        to: nested.appending(path: "Projects.org"),
        atomically: true,
        encoding: .utf8
    )
    try "not knowledge".write(
        to: root.appending(path: "ignored.txt"),
        atomically: true,
        encoding: .utf8
    )

    let result = try SourceDirectoryScanner().scan(
        SourceDirectory(url: root)
    )

    #expect(result.fileCount == 2)
    #expect(result.parsedFileCount == 2)
    #expect(result.reusedFileCount == 0)
    #expect(result.fingerprints.count == 2)
    #expect(result.entities.count == 6)
    #expect(result.entities.contains { $0.title == "Inbox" })
    #expect(result.entities.contains {
        $0.title == "Index sources" && $0.kind == .task
    })
    #expect(result.diagnostics.isEmpty)
}

@Test
func scannerReusesUnchangedFilesRetainsFailuresAndConfirmsDeletions() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "BrainSurfacerIncremental-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let changingFile = root.appending(path: "Changing.md")
    let fragileFile = root.appending(path: "Fragile.org")
    try "# Original".write(to: changingFile, atomically: true, encoding: .utf8)
    try "* Last known good".write(to: fragileFile, atomically: true, encoding: .utf8)

    let scanner = SourceDirectoryScanner()
    let source = SourceDirectory(url: root)
    let initial = try scanner.scan(source)
    let unchanged = try scanner.scan(
        source,
        previousFingerprints: initial.fingerprints,
        previousEntities: initial.entities
    )

    #expect(unchanged.parsedFileCount == 0)
    #expect(unchanged.reusedFileCount == 2)
    #expect(unchanged.entities == initial.entities)

    try "# Updated with a different size".write(
        to: changingFile,
        atomically: true,
        encoding: .utf8
    )
    let changed = try scanner.scan(
        source,
        previousFingerprints: unchanged.fingerprints,
        previousEntities: unchanged.entities
    )

    #expect(changed.parsedFileCount == 1)
    #expect(changed.reusedFileCount == 1)
    #expect(changed.entities.contains { $0.title == "Updated with a different size" })

    try Data([0xFF, 0xFE, 0xFD]).write(to: fragileFile, options: [.atomic])
    let retained = try scanner.scan(
        source,
        previousFingerprints: changed.fingerprints,
        previousEntities: changed.entities
    )

    #expect(retained.diagnostics.count == 1)
    #expect(retained.entities.contains { $0.title == "Last known good" })
    #expect(retained.fingerprints[fragileFile.standardizedFileURL]
        == changed.fingerprints[fragileFile.standardizedFileURL])

    try FileManager.default.removeItem(at: changingFile)
    let deleted = try scanner.scan(
        source,
        previousFingerprints: retained.fingerprints,
        previousEntities: retained.entities
    )

    #expect(!deleted.entities.contains {
        $0.source.fileURL.standardizedFileURL == changingFile.standardizedFileURL
    })
    #expect(deleted.fingerprints[changingFile.standardizedFileURL] == nil)
    #expect(deleted.entities.contains { $0.title == "Last known good" })
}

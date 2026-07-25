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
    #expect(result.entities.count == 6)
    #expect(result.entities.contains { $0.title == "Inbox" })
    #expect(result.entities.contains {
        $0.title == "Index sources" && $0.kind == .task
    })
    #expect(result.diagnostics.isEmpty)
}

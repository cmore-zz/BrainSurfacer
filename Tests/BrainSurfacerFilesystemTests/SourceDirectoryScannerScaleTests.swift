import BrainSurfacerFilesystem
import Foundation
import Testing

@Test(
    .enabled(
        if: ProcessInfo.processInfo.environment["BRAINSURFACER_RUN_SCALE_TESTS"] == "1",
        "Set BRAINSURFACER_RUN_SCALE_TESTS=1 to run the 20,000-note scan."
    )
)
func scannerHandlesTwentyThousandNotesIncrementally() async throws {
    let noteCount = 20_000
    let root = FileManager.default.temporaryDirectory
        .appending(path: "BrainSurfacerScale-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    for index in 0..<noteCount {
        try Data("# Note \(index)\n".utf8).write(
            to: root.appending(path: "Note-\(index).md")
        )
    }

    let scanner = SourceDirectoryScanner(maximumConcurrentFileParses: 8)
    let source = SourceDirectory(
        url: root,
        pathPolicy: SourcePathPolicy(includePatterns: ["**/*.md"])
    )
    let initial = try await scanner.scan(source)

    #expect(initial.fileCount == noteCount)
    #expect(initial.parsedFileCount == noteCount)
    #expect(initial.reusedFileCount == 0)
    #expect(initial.entities.count == noteCount * 2)
    #expect(initial.fingerprints.count == noteCount)
    #expect(initial.diagnostics.isEmpty)

    let unchanged = try await scanner.scan(
        source,
        previousFingerprints: initial.fingerprints,
        previousEntities: initial.entities
    )

    #expect(unchanged.fileCount == noteCount)
    #expect(unchanged.parsedFileCount == 0)
    #expect(unchanged.reusedFileCount == noteCount)
    #expect(unchanged.entities == initial.entities)
    #expect(unchanged.diagnostics.isEmpty)
}

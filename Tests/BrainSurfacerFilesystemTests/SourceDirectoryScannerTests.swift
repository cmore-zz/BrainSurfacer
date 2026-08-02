@testable import BrainSurfacerFilesystem
import BrainSurfacerModel
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

    let result = try await SourceDirectoryScanner().scan(
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
func scannerReusesUnchangedFilesRetainsFailuresAndConfirmsDeletions() async throws {
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
    let initial = try await scanner.scan(source)
    let unchanged = try await scanner.scan(
        source,
        previousFingerprints: initial.fingerprints,
        previousEntities: initial.entities
    )

    #expect(unchanged.parsedFileCount == 0)
    #expect(unchanged.reusedFileCount == 2)
    #expect(unchanged.entities == initial.entities)

    let obsoleteParserFingerprints = unchanged.fingerprints.mapValues {
        SourceFileFingerprint(
            modifiedAt: $0.modifiedAt,
            fileSize: $0.fileSize,
            parserRevision: OutlineParser.outputRevision - 1
        )
    }
    let parserUpdated = try await scanner.scan(
        source,
        previousFingerprints: obsoleteParserFingerprints,
        previousEntities: unchanged.entities
    )

    #expect(parserUpdated.parsedFileCount == 2)
    #expect(parserUpdated.reusedFileCount == 0)

    try "# Updated with a different size".write(
        to: changingFile,
        atomically: true,
        encoding: .utf8
    )
    let changed = try await scanner.scan(
        source,
        previousFingerprints: parserUpdated.fingerprints,
        previousEntities: parserUpdated.entities
    )

    #expect(changed.parsedFileCount == 1)
    #expect(changed.reusedFileCount == 1)
    #expect(changed.entities.contains { $0.title == "Updated with a different size" })

    try Data([0xFF, 0xFE, 0xFD]).write(to: fragileFile, options: [.atomic])
    let retained = try await scanner.scan(
        source,
        previousFingerprints: changed.fingerprints,
        previousEntities: changed.entities
    )

    #expect(retained.diagnostics.count == 1)
    #expect(retained.entities.contains { $0.title == "Last known good" })
    #expect(retained.fingerprints[fragileFile.standardizedFileURL]
        == changed.fingerprints[fragileFile.standardizedFileURL])

    try FileManager.default.removeItem(at: changingFile)
    let deleted = try await scanner.scan(
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

@Test
func scannerBoundsConcurrentParsing() async throws {
    let root = try makeScannerFixture(fileCount: 12)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let probe = ParallelParseProbe(delay: .milliseconds(20))
    let scanner = SourceDirectoryScanner(maximumConcurrentFileParses: 3) {
        try await probe.parse($0)
    }
    let result = try await scanner.scan(SourceDirectory(url: root))

    #expect(result.fileCount == 12)
    #expect(result.parsedFileCount == 12)
    #expect(await probe.callCount == 12)
    #expect(await probe.maximumActiveCount == 3)
}

@Test
func scannerCancellationStopsFeedingPendingFiles() async throws {
    let root = try makeScannerFixture(fileCount: 12)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let probe = SuspendedParseProbe(expectedInitialCount: 2)
    let scanner = SourceDirectoryScanner(maximumConcurrentFileParses: 2) {
        try await probe.parse($0)
    }
    let scanTask = Task {
        try await scanner.scan(SourceDirectory(url: root))
    }

    await probe.waitUntilInitialParsesStart()
    scanTask.cancel()

    await #expect(throws: CancellationError.self) {
        try await scanTask.value
    }
    #expect(await probe.startedCount == 2)
}

private func makeScannerFixture(fileCount: Int) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "BrainSurfacerParallel-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    for index in 0..<fileCount {
        try "# Note \(index)".write(
            to: root.appending(path: "Note-\(index).md"),
            atomically: true,
            encoding: .utf8
        )
    }
    return root
}

private actor ParallelParseProbe {
    private let delay: Duration
    private var activeCount = 0
    private(set) var callCount = 0
    private(set) var maximumActiveCount = 0

    init(delay: Duration) {
        self.delay = delay
    }

    func parse(_ request: SourceFileParseRequest) async throws -> [KnowledgeEntity] {
        callCount += 1
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        do {
            try await Task.sleep(for: delay)
        } catch {
            activeCount -= 1
            throw error
        }
        activeCount -= 1
        return []
    }
}

private actor SuspendedParseProbe {
    private let expectedInitialCount: Int
    private var initialParseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var startedCount = 0

    init(expectedInitialCount: Int) {
        self.expectedInitialCount = expectedInitialCount
    }

    func parse(_ request: SourceFileParseRequest) async throws -> [KnowledgeEntity] {
        startedCount += 1
        if startedCount == expectedInitialCount {
            let waiters = initialParseWaiters
            initialParseWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
        try await Task.sleep(for: .seconds(60))
        return []
    }

    func waitUntilInitialParsesStart() async {
        guard startedCount < expectedInitialCount else {
            return
        }
        await withCheckedContinuation { continuation in
            initialParseWaiters.append(continuation)
        }
    }
}

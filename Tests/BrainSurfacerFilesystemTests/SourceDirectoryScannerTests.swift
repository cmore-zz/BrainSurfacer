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
func scannerAppliesPathPoliciesAndReconcilesPolicyChanges() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "BrainSurfacerPolicies-\(UUID().uuidString)", directoryHint: .isDirectory)
    let projects = root.appending(path: "Projects", directoryHint: .isDirectory)
    let archive = projects.appending(path: "Archive", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: archive,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let files = [
        root.appending(path: "Root.md"),
        root.appending(path: "Root.org"),
        projects.appending(path: "Notes.md"),
        projects.appending(path: "Plan.org"),
        archive.appending(path: "Old.md")
    ]
    for file in files {
        try "# \(file.deletingPathExtension().lastPathComponent)".write(
            to: file,
            atomically: true,
            encoding: .utf8
        )
    }

    let scanner = SourceDirectoryScanner()
    let unrestricted = try await scanner.scan(SourceDirectory(url: root))
    let filteredSource = SourceDirectory(
        url: root,
        pathPolicy: SourcePathPolicy(
            includePatterns: ["**/*.md", "Projects/**/*.org"],
            excludePatterns: ["Projects/Archive/**"]
        )
    )
    let filtered = try await scanner.scan(
        filteredSource,
        previousFingerprints: unrestricted.fingerprints,
        previousEntities: unrestricted.entities
    )
    let filteredFileNames = Set(
        filtered.entities.map { $0.source.fileURL.lastPathComponent }
    )

    #expect(unrestricted.fileCount == 5)
    #expect(filtered.fileCount == 3)
    #expect(filtered.parsedFileCount == 0)
    #expect(filtered.reusedFileCount == 3)
    #expect(filtered.fingerprints.count == 3)
    #expect(filteredFileNames == ["Root.md", "Notes.md", "Plan.org"])

    let expanded = try await scanner.scan(
        SourceDirectory(url: root),
        previousFingerprints: filtered.fingerprints,
        previousEntities: filtered.entities
    )
    #expect(expanded.fileCount == 5)
    #expect(expanded.parsedFileCount == 2)
    #expect(expanded.reusedFileCount == 3)

    let nested = try await scanner.scan(
        SourceDirectory(
            url: projects,
            pathPolicy: SourcePathPolicy(
                includePatterns: ["*.org"],
                excludePatterns: ["Archive/**"]
            )
        )
    )
    #expect(nested.fileCount == 1)
    #expect(Set(nested.entities.map { $0.source.fileURL.lastPathComponent }) == ["Plan.org"])
}

@Test
func incompleteEnumerationRetainsIncludedFilesButDropsPolicyExclusions() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "BrainSurfacerIncompletePolicy-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let retainedFile = root.appending(path: "Retained.md")
    let excludedFile = root.appending(path: "Excluded.md")
    try "# Retained".write(to: retainedFile, atomically: true, encoding: .utf8)
    try "# Excluded".write(to: excludedFile, atomically: true, encoding: .utf8)

    let initial = try await SourceDirectoryScanner().scan(
        SourceDirectory(url: root)
    )
    let unreadableDirectory = root.appending(
        path: "Unreadable",
        directoryHint: .isDirectory
    )
    let incompleteScanner = SourceDirectoryScanner(
        enumerationSnapshot: SourceDirectoryEnumerationSnapshot(
            candidateURLs: [],
            diagnostics: [
                SourceScanDiagnostic(
                    fileURL: unreadableDirectory,
                    message: "Permission denied"
                )
            ],
            wasComplete: false
        )
    )
    let result = try await incompleteScanner.scan(
        SourceDirectory(
            url: root,
            pathPolicy: SourcePathPolicy(excludePatterns: ["Excluded.md"])
        ),
        previousFingerprints: initial.fingerprints,
        previousEntities: initial.entities
    )

    #expect(result.fileCount == 1)
    #expect(result.parsedFileCount == 0)
    #expect(result.diagnostics == [
        SourceScanDiagnostic(
            fileURL: unreadableDirectory,
            message: "Permission denied"
        )
    ])
    #expect(result.entities.allSatisfy {
        $0.source.fileURL.standardizedFileURL == retainedFile.standardizedFileURL
    })
    #expect(Set(result.fingerprints.keys) == [retainedFile.standardizedFileURL])
    #expect(!result.entities.contains {
        $0.source.fileURL.standardizedFileURL == excludedFile.standardizedFileURL
    })
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

@Test
func scannerOrdersDuplicateCanonicalIDsIndependentlyOfCompletionOrder() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "BrainSurfacerDuplicateIDs-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    try """
    * Alpha
    :PROPERTIES:
    :ID: shared-duplicate-id
    :END:
    Alpha body
    """.write(
        to: root.appending(path: "A.org"),
        atomically: true,
        encoding: .utf8
    )
    try """
    * Beta
    :PROPERTIES:
    :ID: shared-duplicate-id
    :END:
    Beta body
    """.write(
        to: root.appending(path: "B.org"),
        atomically: true,
        encoding: .utf8
    )

    let source = SourceDirectory(url: root)
    let firstCompletions = ParseCompletionRecorder(delayedFileName: "A.org")
    let first = try await scanDuplicateIDFixture(
        source,
        completions: firstCompletions
    )
    let secondCompletions = ParseCompletionRecorder(delayedFileName: "B.org")
    let second = try await scanDuplicateIDFixture(
        source,
        completions: secondCompletions
    )

    #expect(await firstCompletions.fileNames == ["B.org", "A.org"])
    #expect(await secondCompletions.fileNames == ["A.org", "B.org"])
    #expect(first.entities == second.entities)
    #expect(first.entities.filter {
        $0.id.rawValue == "org-id:shared-duplicate-id"
    }.map { $0.source.fileURL.lastPathComponent } == ["A.org", "B.org"])
}

private func scanDuplicateIDFixture(
    _ source: SourceDirectory,
    completions: ParseCompletionRecorder
) async throws -> SourceScanResult {
    let parser = OutlineParser()
    let scanner = SourceDirectoryScanner(maximumConcurrentFileParses: 2) { request in
        let contents = try String(contentsOf: request.fileURL, encoding: .utf8)
        let entities = parser.parse(
            SourceDocument(
                fileURL: request.fileURL,
                format: request.format,
                contents: contents,
                modifiedAt: request.modifiedAt
            )
        )
        await completions.finish(request.fileURL.lastPathComponent)
        return entities
    }
    return try await scanner.scan(source)
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

private actor ParseCompletionRecorder {
    private let delayedFileName: String
    private var delayedWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var fileNames: [String] = []

    init(delayedFileName: String) {
        self.delayedFileName = delayedFileName
    }

    func finish(_ fileName: String) async {
        if fileName == delayedFileName, fileNames.isEmpty {
            await withCheckedContinuation { continuation in
                delayedWaiters.append(continuation)
            }
        }
        fileNames.append(fileName)
        if fileName != delayedFileName {
            let waiters = delayedWaiters
            delayedWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }
}

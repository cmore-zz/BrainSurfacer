import BrainSurfacerModel
import Foundation

public struct SourceScanDiagnostic: Equatable, Sendable {
    public var fileURL: URL
    public var message: String

    public init(fileURL: URL, message: String) {
        self.fileURL = fileURL
        self.message = message
    }
}

public struct SourceScanResult: Equatable, Sendable {
    public var source: SourceDirectory
    public var fileCount: Int
    public var parsedFileCount: Int
    public var reusedFileCount: Int
    public var entities: [KnowledgeEntity]
    public var diagnostics: [SourceScanDiagnostic]
    public var fingerprints: [URL: SourceFileFingerprint]

    public init(
        source: SourceDirectory,
        fileCount: Int,
        parsedFileCount: Int? = nil,
        reusedFileCount: Int = 0,
        entities: [KnowledgeEntity],
        diagnostics: [SourceScanDiagnostic],
        fingerprints: [URL: SourceFileFingerprint] = [:]
    ) {
        self.source = source
        self.fileCount = fileCount
        self.parsedFileCount = parsedFileCount ?? fileCount
        self.reusedFileCount = reusedFileCount
        self.entities = entities
        self.diagnostics = diagnostics
        self.fingerprints = fingerprints
    }
}

public struct SourceDirectoryScanner: Sendable {
    public enum Error: LocalizedError {
        case cannotEnumerate(URL)

        public var errorDescription: String? {
            switch self {
            case let .cannotEnumerate(url):
                "BrainSurfacer couldn’t enumerate \"\(url.lastPathComponent)\"."
            }
        }
    }

    private let maximumConcurrentFileParses: Int
    private let enumerationSnapshot: SourceDirectoryEnumerationSnapshot?
    private let fileParser: @Sendable (SourceFileParseRequest) async throws -> [KnowledgeEntity]

    public init(
        parser: OutlineParser = OutlineParser(),
        maximumConcurrentFileParses: Int = 4
    ) {
        self.init(
            maximumConcurrentFileParses: maximumConcurrentFileParses,
            enumerationSnapshot: nil,
            fileParser: Self.productionFileParser(parser: parser)
        )
    }

    init(
        maximumConcurrentFileParses: Int,
        fileParser: @escaping @Sendable (SourceFileParseRequest) async throws -> [KnowledgeEntity]
    ) {
        self.init(
            maximumConcurrentFileParses: maximumConcurrentFileParses,
            enumerationSnapshot: nil,
            fileParser: fileParser
        )
    }

    init(
        parser: OutlineParser = OutlineParser(),
        maximumConcurrentFileParses: Int = 4,
        enumerationSnapshot: SourceDirectoryEnumerationSnapshot
    ) {
        self.init(
            maximumConcurrentFileParses: maximumConcurrentFileParses,
            enumerationSnapshot: enumerationSnapshot,
            fileParser: Self.productionFileParser(parser: parser)
        )
    }

    private init(
        maximumConcurrentFileParses: Int,
        enumerationSnapshot: SourceDirectoryEnumerationSnapshot?,
        fileParser: @escaping @Sendable (SourceFileParseRequest) async throws -> [KnowledgeEntity]
    ) {
        self.maximumConcurrentFileParses = max(1, maximumConcurrentFileParses)
        self.enumerationSnapshot = enumerationSnapshot
        self.fileParser = fileParser
    }

    public func scan(
        _ source: SourceDirectory,
        previousFingerprints: [URL: SourceFileFingerprint] = [:],
        previousEntities: [KnowledgeEntity] = []
    ) async throws -> SourceScanResult {
        let root = source.url
        let didStartAccess = root.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                root.stopAccessingSecurityScopedResource()
            }
        }

        let previousFingerprints = Dictionary(
            previousFingerprints.map { ($0.key.standardizedFileURL, $0.value) },
            uniquingKeysWith: { _, latest in latest }
        )
        let previousEntitiesByFile = Dictionary(
            grouping: previousEntities,
            by: { $0.source.fileURL.standardizedFileURL }
        )
        var enumeration = try enumerateFiles(
            at: root,
            pathPolicy: source.pathPolicy,
            previousFingerprints: previousFingerprints,
            previousEntitiesByFile: previousEntitiesByFile
        )
        try Task.checkCancellation()
        let parsedFiles = try await parseFiles(enumeration.pendingFiles)
        enumeration.entities.append(contentsOf: parsedFiles.entities)
        enumeration.fingerprints.merge(
            parsedFiles.fingerprints,
            uniquingKeysWith: { _, latest in latest }
        )
        enumeration.diagnostics.append(contentsOf: parsedFiles.diagnostics)

        if !enumeration.wasComplete {
            let previouslyKnownFiles = Set(previousFingerprints.keys)
                .union(previousEntitiesByFile.keys)
            for fileURL in previouslyKnownFiles.subtracting(enumeration.seenFiles) {
                guard let relativePath = relativePath(of: fileURL, from: root),
                      source.pathPolicy.includes(relativePath: relativePath) else {
                    continue
                }
                enumeration.entities.append(
                    contentsOf: previousEntitiesByFile[fileURL, default: []]
                )
                if let previousFingerprint = previousFingerprints[fileURL] {
                    enumeration.fingerprints[fileURL] = previousFingerprint
                }
                enumeration.fileCount += 1
            }
        }

        enumeration.entities.sort(by: entitiesAreInDeterministicOrder)
        enumeration.diagnostics.sort {
            $0.fileURL.path.localizedStandardCompare($1.fileURL.path)
                == .orderedAscending
        }

        return SourceScanResult(
            source: source,
            fileCount: enumeration.fileCount,
            parsedFileCount: parsedFiles.parsedFileCount,
            reusedFileCount: enumeration.reusedFileCount,
            entities: enumeration.entities,
            diagnostics: enumeration.diagnostics,
            fingerprints: enumeration.fingerprints
        )
    }

    private func enumerateFiles(
        at root: URL,
        pathPolicy: SourcePathPolicy,
        previousFingerprints: [URL: SourceFileFingerprint],
        previousEntitiesByFile: [URL: [KnowledgeEntity]]
    ) throws -> SourceFileEnumeration {
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .fileSizeKey
        ]
        var result = SourceFileEnumeration()
        if let enumerationSnapshot {
            result.wasComplete = enumerationSnapshot.wasComplete
            result.diagnostics = enumerationSnapshot.diagnostics
            for candidateURL in enumerationSnapshot.candidateURLs {
                try processCandidate(
                    candidateURL,
                    root: root,
                    pathPolicy: pathPolicy,
                    resourceKeys: resourceKeys,
                    previousFingerprints: previousFingerprints,
                    previousEntitiesByFile: previousEntitiesByFile,
                    result: &result
                )
            }
            return result
        }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { fileURL, error in
                result.wasComplete = false
                result.diagnostics.append(
                    SourceScanDiagnostic(
                        fileURL: fileURL,
                        message: error.localizedDescription
                    )
                )
                return true
            }
        ) else {
            throw Error.cannotEnumerate(root)
        }

        for case let candidateURL as URL in enumerator {
            try processCandidate(
                candidateURL,
                root: root,
                pathPolicy: pathPolicy,
                resourceKeys: resourceKeys,
                previousFingerprints: previousFingerprints,
                previousEntitiesByFile: previousEntitiesByFile,
                result: &result
            )
        }

        return result
    }

    private func processCandidate(
        _ candidateURL: URL,
        root: URL,
        pathPolicy: SourcePathPolicy,
        resourceKeys: Set<URLResourceKey>,
        previousFingerprints: [URL: SourceFileFingerprint],
        previousEntitiesByFile: [URL: [KnowledgeEntity]],
        result: inout SourceFileEnumeration
    ) throws {
        try Task.checkCancellation()
        guard let format = format(for: candidateURL) else {
            return
        }
        let fileURL = candidateURL.standardizedFileURL
        guard let relativePath = relativePath(of: fileURL, from: root),
              pathPolicy.includes(relativePath: relativePath) else {
            return
        }
        result.seenFiles.insert(fileURL)
        let previousFileEntities = previousEntitiesByFile[fileURL, default: []]

        do {
            let values = try fileURL.resourceValues(forKeys: resourceKeys)
            guard values.isSymbolicLink != true,
                  values.isRegularFile == true else {
                return
            }
            result.fileCount += 1
            let currentFingerprint = fingerprint(from: values)
            if let currentFingerprint,
               currentFingerprint == previousFingerprints[fileURL],
               !previousFileEntities.isEmpty {
                result.entities.append(contentsOf: previousFileEntities)
                result.fingerprints[fileURL] = currentFingerprint
                result.reusedFileCount += 1
                return
            }

            result.pendingFiles.append(
                SourceFileParseRequest(
                    fileURL: fileURL,
                    format: format,
                    modifiedAt: values.contentModificationDate,
                    currentFingerprint: currentFingerprint,
                    previousFingerprint: previousFingerprints[fileURL],
                    previousEntities: previousFileEntities
                )
            )
        } catch {
            result.entities.append(contentsOf: previousFileEntities)
            if let previousFingerprint = previousFingerprints[fileURL] {
                result.fingerprints[fileURL] = previousFingerprint
            }
            result.diagnostics.append(
                SourceScanDiagnostic(
                    fileURL: fileURL,
                    message: error.localizedDescription
                )
            )
        }
    }

    private func parseFiles(
        _ requests: [SourceFileParseRequest]
    ) async throws -> SourceFileParseBatch {
        guard !requests.isEmpty else {
            return SourceFileParseBatch()
        }

        return try await withThrowingTaskGroup(
            of: SourceFileParseOutcome.self
        ) { group in
            let initialCount = min(maximumConcurrentFileParses, requests.count)
            for request in requests.prefix(initialCount) {
                group.addTask {
                    try await parseFile(request)
                }
            }

            var nextIndex = initialCount
            var batch = SourceFileParseBatch()
            while let outcome = try await group.next() {
                batch.record(outcome)
                if nextIndex < requests.count {
                    try Task.checkCancellation()
                    let request = requests[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        try await parseFile(request)
                    }
                }
            }
            return batch
        }
    }

    private func parseFile(
        _ request: SourceFileParseRequest
    ) async throws -> SourceFileParseOutcome {
        do {
            try Task.checkCancellation()
            let parsedEntities = try await fileParser(request)
            try Task.checkCancellation()
            return SourceFileParseOutcome(
                fileURL: request.fileURL,
                entities: parsedEntities,
                fingerprint: request.currentFingerprint,
                diagnosticMessage: nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return SourceFileParseOutcome(
                fileURL: request.fileURL,
                entities: request.previousEntities,
                fingerprint: request.previousFingerprint,
                diagnosticMessage: error.localizedDescription
            )
        }
    }

    private func fingerprint(from values: URLResourceValues) -> SourceFileFingerprint? {
        guard let modifiedAt = values.contentModificationDate,
              let fileSize = values.fileSize else {
            return nil
        }
        return SourceFileFingerprint(
            modifiedAt: modifiedAt,
            fileSize: Int64(fileSize)
        )
    }

    private func entitiesAreInDeterministicOrder(
        _ lhs: KnowledgeEntity,
        _ rhs: KnowledgeEntity
    ) -> Bool {
        if lhs.id.rawValue != rhs.id.rawValue {
            return lhs.id.rawValue < rhs.id.rawValue
        }

        let lhsPath = lhs.source.fileURL.standardizedFileURL.path
        let rhsPath = rhs.source.fileURL.standardizedFileURL.path
        if lhsPath != rhsPath {
            return lhsPath < rhsPath
        }

        let lhsOffset = lhs.source.byteOffset ?? -1
        let rhsOffset = rhs.source.byteOffset ?? -1
        if lhsOffset != rhsOffset {
            return lhsOffset < rhsOffset
        }

        let lhsLine = lhs.source.line ?? -1
        let rhsLine = rhs.source.line ?? -1
        if lhsLine != rhsLine {
            return lhsLine < rhsLine
        }

        let lhsColumn = lhs.source.column ?? -1
        let rhsColumn = rhs.source.column ?? -1
        if lhsColumn != rhsColumn {
            return lhsColumn < rhsColumn
        }

        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return lhs.title < rhs.title
    }

    private func relativePath(of fileURL: URL, from root: URL) -> String? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        guard fileComponents.count > rootComponents.count,
              fileComponents.prefix(rootComponents.count)
                .elementsEqual(rootComponents) else {
            return nil
        }
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private func format(for fileURL: URL) -> SourceDocument.Format? {
        switch fileURL.pathExtension.lowercased() {
        case "md", "markdown":
            .markdown
        case "org":
            .org
        default:
            nil
        }
    }

    private static func productionFileParser(
        parser: OutlineParser
    ) -> @Sendable (SourceFileParseRequest) async throws -> [KnowledgeEntity] {
        { request in
            try Task.checkCancellation()
            let contents = try String(
                contentsOf: request.fileURL,
                encoding: .utf8
            )
            try Task.checkCancellation()
            return parser.parse(
                SourceDocument(
                    fileURL: request.fileURL,
                    format: request.format,
                    contents: contents,
                    modifiedAt: request.modifiedAt
                )
            )
        }
    }
}

struct SourceDirectoryEnumerationSnapshot: Sendable {
    let candidateURLs: [URL]
    let diagnostics: [SourceScanDiagnostic]
    let wasComplete: Bool
}

struct SourceFileParseRequest: Sendable {
    let fileURL: URL
    let format: SourceDocument.Format
    let modifiedAt: Date?
    let currentFingerprint: SourceFileFingerprint?
    let previousFingerprint: SourceFileFingerprint?
    let previousEntities: [KnowledgeEntity]
}

private struct SourceFileEnumeration {
    var fileCount = 0
    var reusedFileCount = 0
    var entities: [KnowledgeEntity] = []
    var diagnostics: [SourceScanDiagnostic] = []
    var fingerprints: [URL: SourceFileFingerprint] = [:]
    var seenFiles: Set<URL> = []
    var pendingFiles: [SourceFileParseRequest] = []
    var wasComplete = true
}

private struct SourceFileParseOutcome: Sendable {
    let fileURL: URL
    let entities: [KnowledgeEntity]
    let fingerprint: SourceFileFingerprint?
    let diagnosticMessage: String?
}

private struct SourceFileParseBatch {
    var parsedFileCount = 0
    var entities: [KnowledgeEntity] = []
    var diagnostics: [SourceScanDiagnostic] = []
    var fingerprints: [URL: SourceFileFingerprint] = [:]

    mutating func record(_ outcome: SourceFileParseOutcome) {
        entities.append(contentsOf: outcome.entities)
        if let fingerprint = outcome.fingerprint {
            fingerprints[outcome.fileURL] = fingerprint
        }
        if let diagnosticMessage = outcome.diagnosticMessage {
            diagnostics.append(
                SourceScanDiagnostic(
                    fileURL: outcome.fileURL,
                    message: diagnosticMessage
                )
            )
        } else {
            parsedFileCount += 1
        }
    }
}

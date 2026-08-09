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
    private let formatRegistry: SourceFormatRegistry
    private let fileParser: @Sendable (SourceFileParseRequest) async throws -> SourceDocumentParseResult

    public init(
        parser: OutlineParser = OutlineParser(),
        maximumConcurrentFileParses: Int = 4
    ) {
        self.init(
            maximumConcurrentFileParses: maximumConcurrentFileParses,
            enumerationSnapshot: nil,
            formatRegistry: .standard(parser: parser),
            parsedFileProvider: Self.productionFileParser()
        )
    }

    public init(
        formatRegistry: SourceFormatRegistry,
        maximumConcurrentFileParses: Int = 4
    ) {
        self.init(
            maximumConcurrentFileParses: maximumConcurrentFileParses,
            enumerationSnapshot: nil,
            formatRegistry: formatRegistry,
            parsedFileProvider: Self.productionFileParser()
        )
    }

    init(
        maximumConcurrentFileParses: Int,
        fileParser: @escaping @Sendable (SourceFileParseRequest) async throws -> [KnowledgeEntity]
    ) {
        self.init(
            maximumConcurrentFileParses: maximumConcurrentFileParses,
            enumerationSnapshot: nil,
            formatRegistry: .standard(),
            parsedFileProvider: { request in
                SourceDocumentParseResult(
                    entities: try await fileParser(request),
                    wasExcludedByDocumentMetadata: false
                )
            }
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
            formatRegistry: .standard(parser: parser),
            parsedFileProvider: Self.productionFileParser()
        )
    }

    private init(
        maximumConcurrentFileParses: Int,
        enumerationSnapshot: SourceDirectoryEnumerationSnapshot?,
        formatRegistry: SourceFormatRegistry,
        parsedFileProvider: @escaping @Sendable (SourceFileParseRequest) async throws -> SourceDocumentParseResult
    ) {
        self.maximumConcurrentFileParses = max(1, maximumConcurrentFileParses)
        self.enumerationSnapshot = enumerationSnapshot
        self.formatRegistry = formatRegistry
        self.fileParser = parsedFileProvider
    }

    public func scan(
        _ source: SourceDirectory,
        previousFingerprints: [URL: SourceFileFingerprint] = [:],
        previousEntities: [KnowledgeEntity] = []
    ) async throws -> SourceScanResult {
        try Task.checkCancellation()
        guard source.indexingMode != .paused else {
            return SourceScanResult(
                source: source,
                fileCount: 0,
                parsedFileCount: 0,
                entities: [],
                diagnostics: [],
                fingerprints: [:]
            )
        }
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
            indexingMode: source.indexingMode,
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
                    var retainedFingerprint = previousFingerprint
                    if source.indexingMode == .metadataOnly {
                        retainedFingerprint.indexingMode = .metadataOnly
                    }
                    enumeration.fingerprints[fileURL] = retainedFingerprint
                }
                enumeration.fileCount += 1
            }
        }

        // Privacy-critical: keep this as the final entity transform so fresh,
        // reused, and last-known-good entities are stripped before projection.
        enumeration.entities = source.indexingMode.applying(
            to: enumeration.entities
        )
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
        indexingMode: SourceIndexingMode,
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
                    indexingMode: indexingMode,
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
                indexingMode: indexingMode,
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
        indexingMode: SourceIndexingMode,
        resourceKeys: Set<URLResourceKey>,
        previousFingerprints: [URL: SourceFileFingerprint],
        previousEntitiesByFile: [URL: [KnowledgeEntity]],
        result: inout SourceFileEnumeration
    ) throws {
        try Task.checkCancellation()
        guard let formatMatch = formatRegistry.match(for: candidateURL) else {
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
            let currentFingerprint = fingerprint(
                from: values,
                formatRegistration: formatMatch.registration,
                indexingMode: indexingMode,
                wasExcludedByDocumentMetadata: previousFingerprints[fileURL]?
                    .wasExcludedByDocumentMetadata ?? false
            )
            if let currentFingerprint,
               currentFingerprint == previousFingerprints[fileURL],
               currentFingerprint.wasExcludedByDocumentMetadata
                    || !previousFileEntities.isEmpty {
                if !currentFingerprint.wasExcludedByDocumentMetadata {
                    result.entities.append(contentsOf: previousFileEntities)
                }
                result.fingerprints[fileURL] = currentFingerprint
                result.reusedFileCount += 1
                return
            }

            result.pendingFiles.append(
                SourceFileParseRequest(
                    fileURL: fileURL,
                    formatRegistration: formatMatch.registration,
                    filenameSuffix: formatMatch.filenameSuffix,
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
            let parsed = try await fileParser(request)
            try Task.checkCancellation()
            var fingerprint = request.currentFingerprint
            fingerprint?.wasExcludedByDocumentMetadata =
                parsed.wasExcludedByDocumentMetadata
            return SourceFileParseOutcome(
                fileURL: request.fileURL,
                entities: parsed.entities,
                fingerprint: fingerprint,
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

    private func fingerprint(
        from values: URLResourceValues,
        formatRegistration: SourceFormatRegistration,
        indexingMode: SourceIndexingMode,
        wasExcludedByDocumentMetadata: Bool
    ) -> SourceFileFingerprint? {
        guard let modifiedAt = values.contentModificationDate,
              let fileSize = values.fileSize else {
            return nil
        }
        return SourceFileFingerprint(
            modifiedAt: modifiedAt,
            fileSize: Int64(fileSize),
            parserIdentifier: formatRegistration.parserIdentifier,
            parserRevision: formatRegistration.parserRevision,
            indexingMode: indexingMode,
            wasExcludedByDocumentMetadata: wasExcludedByDocumentMetadata
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

    private static func productionFileParser()
        -> @Sendable (SourceFileParseRequest) async throws -> SourceDocumentParseResult {
        { request in
            try Task.checkCancellation()
            let data = try Data(contentsOf: request.fileURL)
            try Task.checkCancellation()
            guard let contents = String(data: data, encoding: .utf8) else {
                let lossyDocument = SourceDocument(
                    fileURL: request.fileURL,
                    format: request.format,
                    filenameSuffix: request.filenameSuffix,
                    contents: String(decoding: data, as: UTF8.self),
                    modifiedAt: request.modifiedAt
                )
                if request.formatRegistration.excludesIndexing(lossyDocument) {
                    return SourceDocumentParseResult(
                        entities: [],
                        wasExcludedByDocumentMetadata: true
                    )
                }
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            return try request.formatRegistration.parseResult(
                SourceDocument(
                    fileURL: request.fileURL,
                    format: request.format,
                    filenameSuffix: request.filenameSuffix,
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
    let formatRegistration: SourceFormatRegistration
    let filenameSuffix: String
    let modifiedAt: Date?
    let currentFingerprint: SourceFileFingerprint?
    let previousFingerprint: SourceFileFingerprint?
    let previousEntities: [KnowledgeEntity]

    var format: SourceDocument.Format {
        formatRegistration.format
    }
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

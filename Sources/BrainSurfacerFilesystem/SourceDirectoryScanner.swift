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

    private let parser: OutlineParser

    public init(parser: OutlineParser = OutlineParser()) {
        self.parser = parser
    }

    public func scan(
        _ source: SourceDirectory,
        previousFingerprints: [URL: SourceFileFingerprint] = [:],
        previousEntities: [KnowledgeEntity] = []
    ) throws -> SourceScanResult {
        let root = source.url
        let didStartAccess = root.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                root.stopAccessingSecurityScopedResource()
            }
        }

        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileSizeKey
        ]
        var diagnostics: [SourceScanDiagnostic] = []
        var enumerationWasComplete = true
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { fileURL, error in
                enumerationWasComplete = false
                diagnostics.append(
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

        let previousFingerprints = Dictionary(
            previousFingerprints.map { ($0.key.standardizedFileURL, $0.value) },
            uniquingKeysWith: { _, latest in latest }
        )
        let previousEntitiesByFile = Dictionary(
            grouping: previousEntities,
            by: { $0.source.fileURL.standardizedFileURL }
        )
        var fileCount = 0
        var parsedFileCount = 0
        var reusedFileCount = 0
        var entities: [KnowledgeEntity] = []
        var fingerprints: [URL: SourceFileFingerprint] = [:]
        var seenFiles: Set<URL> = []

        for case let candidateURL as URL in enumerator {
            try Task.checkCancellation()
            guard let format = format(for: candidateURL) else {
                continue
            }
            let fileURL = candidateURL.standardizedFileURL
            seenFiles.insert(fileURL)
            let previousFileEntities = previousEntitiesByFile[fileURL, default: []]

            do {
                let values = try fileURL.resourceValues(forKeys: resourceKeys)
                guard values.isRegularFile == true else {
                    continue
                }
                fileCount += 1
                let currentFingerprint = fingerprint(from: values)
                if let currentFingerprint,
                   currentFingerprint == previousFingerprints[fileURL],
                   !previousFileEntities.isEmpty {
                    entities.append(contentsOf: previousFileEntities)
                    fingerprints[fileURL] = currentFingerprint
                    reusedFileCount += 1
                    continue
                }

                let contents = try String(contentsOf: fileURL, encoding: .utf8)
                let document = SourceDocument(
                    fileURL: fileURL,
                    format: format,
                    contents: contents,
                    modifiedAt: values.contentModificationDate
                )
                entities.append(contentsOf: parser.parse(document))
                if let currentFingerprint {
                    fingerprints[fileURL] = currentFingerprint
                }
                parsedFileCount += 1
            } catch {
                entities.append(contentsOf: previousFileEntities)
                if let previousFingerprint = previousFingerprints[fileURL] {
                    fingerprints[fileURL] = previousFingerprint
                }
                diagnostics.append(
                    SourceScanDiagnostic(
                        fileURL: fileURL,
                        message: error.localizedDescription
                    )
                )
            }
        }

        if !enumerationWasComplete {
            let previouslyKnownFiles = Set(previousFingerprints.keys)
                .union(previousEntitiesByFile.keys)
            for fileURL in previouslyKnownFiles.subtracting(seenFiles) {
                entities.append(contentsOf: previousEntitiesByFile[fileURL, default: []])
                if let previousFingerprint = previousFingerprints[fileURL] {
                    fingerprints[fileURL] = previousFingerprint
                }
                fileCount += 1
            }
        }

        entities.sort { $0.id.rawValue < $1.id.rawValue }
        diagnostics.sort {
            $0.fileURL.path.localizedStandardCompare($1.fileURL.path)
                == .orderedAscending
        }

        return SourceScanResult(
            source: source,
            fileCount: fileCount,
            parsedFileCount: parsedFileCount,
            reusedFileCount: reusedFileCount,
            entities: entities,
            diagnostics: diagnostics,
            fingerprints: fingerprints
        )
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
}

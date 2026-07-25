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
    public var entities: [KnowledgeEntity]
    public var diagnostics: [SourceScanDiagnostic]

    public init(
        source: SourceDirectory,
        fileCount: Int,
        entities: [KnowledgeEntity],
        diagnostics: [SourceScanDiagnostic]
    ) {
        self.source = source
        self.fileCount = fileCount
        self.entities = entities
        self.diagnostics = diagnostics
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

    public func scan(_ source: SourceDirectory) throws -> SourceScanResult {
        let root = source.url
        let didStartAccess = root.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                root.stopAccessingSecurityScopedResource()
            }
        }

        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .contentModificationDateKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw Error.cannotEnumerate(root)
        }

        var fileCount = 0
        var entities: [KnowledgeEntity] = []
        var diagnostics: [SourceScanDiagnostic] = []

        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()
            guard let format = format(for: fileURL) else {
                continue
            }

            do {
                let values = try fileURL.resourceValues(forKeys: resourceKeys)
                guard values.isRegularFile == true else {
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
                fileCount += 1
            } catch {
                diagnostics.append(
                    SourceScanDiagnostic(
                        fileURL: fileURL,
                        message: error.localizedDescription
                    )
                )
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
            entities: entities,
            diagnostics: diagnostics
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

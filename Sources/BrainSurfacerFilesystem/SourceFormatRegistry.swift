import BrainSurfacerModel
import Foundation

public protocol SourceDocumentParser: Sendable {
    var outputRevision: Int { get }

    func parseResult(_ document: SourceDocument) throws -> SourceDocumentParseResult
    func excludesIndexing(_ document: SourceDocument) -> Bool
}

public struct SourceDocumentParseResult: Sendable {
    public var entities: [KnowledgeEntity]
    public var wasExcludedByDocumentMetadata: Bool

    public init(
        entities: [KnowledgeEntity],
        wasExcludedByDocumentMetadata: Bool
    ) {
        self.entities = entities
        self.wasExcludedByDocumentMetadata = wasExcludedByDocumentMetadata
    }
}

public struct SourceFormatRegistration: Sendable {
    public let parserIdentifier: String
    public let format: SourceDocument.Format
    public let filenameSuffixes: [String]
    public let parserRevision: Int

    private let parseDocument: @Sendable (SourceDocument) throws -> SourceDocumentParseResult
    private let documentExcludesIndexing: @Sendable (SourceDocument) -> Bool

    public init<Parser: SourceDocumentParser>(
        parserIdentifier: String,
        format: SourceDocument.Format,
        filenameSuffixes: [String],
        parser: Parser
    ) {
        self.parserIdentifier = parserIdentifier
        self.format = format
        self.filenameSuffixes = Self.normalizedSuffixes(filenameSuffixes)
        self.parserRevision = parser.outputRevision
        self.parseDocument = { try parser.parseResult($0) }
        self.documentExcludesIndexing = { parser.excludesIndexing($0) }
    }

    func parseResult(_ document: SourceDocument) throws -> SourceDocumentParseResult {
        try parseDocument(document)
    }

    func excludesIndexing(_ document: SourceDocument) -> Bool {
        documentExcludesIndexing(document)
    }

    private static func normalizedSuffixes(_ suffixes: [String]) -> [String] {
        var seen: Set<String> = []
        return suffixes.compactMap { rawSuffix in
            var suffix = rawSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !suffix.isEmpty else {
                return nil
            }
            if !suffix.hasPrefix(".") {
                suffix = "." + suffix
            }
            guard seen.insert(suffix).inserted else {
                return nil
            }
            return suffix
        }
    }
}

public struct SourceFormatRegistry: Sendable {
    /// Registrations are ordered. The longest matching filename suffix wins;
    /// when matching suffixes have equal length, the first registration wins.
    public let registrations: [SourceFormatRegistration]

    public init(registrations: [SourceFormatRegistration]) {
        self.registrations = registrations
    }

    public static func standard(
        parser: OutlineParser = OutlineParser(),
        bbcodeParser: BBCodeParser = BBCodeParser()
    ) -> SourceFormatRegistry {
        SourceFormatRegistry(
            registrations: [
                SourceFormatRegistration(
                    parserIdentifier: "org.brainsurfacer.markdown-outline",
                    format: .markdown,
                    filenameSuffixes: [".md.txt", ".markdown.txt", ".markdown", ".md"],
                    parser: parser
                ),
                SourceFormatRegistration(
                    parserIdentifier: "org.brainsurfacer.org-outline",
                    format: .org,
                    filenameSuffixes: [".org.txt", ".org"],
                    parser: parser
                ),
                SourceFormatRegistration(
                    parserIdentifier: "org.brainsurfacer.bbcode",
                    format: .bbcode,
                    filenameSuffixes: [".bb.txt"],
                    parser: bbcodeParser
                )
            ]
        )
    }

    func match(for fileURL: URL) -> SourceFormatMatch? {
        let filename = fileURL.lastPathComponent.lowercased()
        var bestMatch: SourceFormatMatch?
        for registration in registrations {
            for suffix in registration.filenameSuffixes where filename.hasSuffix(suffix) {
                guard bestMatch.map({ suffix.count > $0.filenameSuffix.count }) ?? true else {
                    continue
                }
                bestMatch = SourceFormatMatch(
                    registration: registration,
                    filenameSuffix: suffix
                )
            }
        }
        return bestMatch
    }
}

struct SourceFormatMatch: Sendable {
    let registration: SourceFormatRegistration
    let filenameSuffix: String
}

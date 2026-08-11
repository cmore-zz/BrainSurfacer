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
    public var wasSkippedByFormatDetection: Bool

    public init(
        entities: [KnowledgeEntity],
        wasExcludedByDocumentMetadata: Bool,
        wasSkippedByFormatDetection: Bool = false
    ) {
        self.entities = entities
        self.wasExcludedByDocumentMetadata = wasExcludedByDocumentMetadata
        self.wasSkippedByFormatDetection = wasSkippedByFormatDetection
    }
}

public struct SourceFormatRegistration: Sendable {
    public let parserIdentifier: String
    public let format: SourceDocument.Format
    public let filenameSuffixes: [String]
    public let parserRevision: Int
    let contentProbeMaximumBytes: Int?

    private let parseDocument: @Sendable (SourceDocument) throws -> SourceDocumentParseResult
    private let documentExcludesIndexing: @Sendable (SourceDocument) -> Bool
    private let contentProbe: (@Sendable (String) -> Bool)?

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
        self.contentProbeMaximumBytes = nil
        self.parseDocument = { try parser.parseResult($0) }
        self.documentExcludesIndexing = { parser.excludesIndexing($0) }
        self.contentProbe = nil
    }

    init<Parser: SourceDocumentParser>(
        parserIdentifier: String,
        format: SourceDocument.Format,
        filenameSuffixes: [String],
        parser: Parser,
        contentProbeMaximumBytes: Int,
        contentProbe: @escaping @Sendable (String) -> Bool
    ) {
        self.parserIdentifier = parserIdentifier
        self.format = format
        self.filenameSuffixes = Self.normalizedSuffixes(filenameSuffixes)
        self.parserRevision = parser.outputRevision
        self.contentProbeMaximumBytes = max(1, contentProbeMaximumBytes)
        self.parseDocument = { try parser.parseResult($0) }
        self.documentExcludesIndexing = { parser.excludesIndexing($0) }
        self.contentProbe = contentProbe
    }

    func parseResult(_ document: SourceDocument) throws -> SourceDocumentParseResult {
        try parseDocument(document)
    }

    func excludesIndexing(_ document: SourceDocument) -> Bool {
        documentExcludesIndexing(document)
    }

    func acceptsContentProbe(_ contents: String) -> Bool {
        contentProbe?(contents) ?? true
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
    private let automaticRegistration: SourceFormatRegistration?

    public init(registrations: [SourceFormatRegistration]) {
        self.registrations = registrations
        self.automaticRegistration = nil
    }

    init(
        registrations: [SourceFormatRegistration],
        automaticRegistration: SourceFormatRegistration
    ) {
        self.registrations = registrations
        self.automaticRegistration = automaticRegistration
    }

    public static func standard(
        parser: OutlineParser = OutlineParser(),
        bbcodeParser: BBCodeParser = BBCodeParser()
    ) -> SourceFormatRegistry {
        let registrations = [
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
        let detector = SourceFormatDetector()
        return SourceFormatRegistry(
            registrations: registrations,
            automaticRegistration: SourceFormatRegistration(
                parserIdentifier: "org.brainsurfacer.automatic-format",
                format: .markdown,
                filenameSuffixes: [],
                parser: AutomaticSourceDocumentParser(
                    registrations: registrations,
                    detector: detector
                ),
                contentProbeMaximumBytes: SourceFormatDetector.maximumInspectedBytes,
                contentProbe: { detector.detect(in: $0) != nil }
            )
        )
    }

    func match(
        for fileURL: URL,
        overrides: [SourceFormatOverride] = []
    ) -> SourceFormatMatch? {
        let filename = fileURL.lastPathComponent.lowercased()
        let builtInMatch = longestRegisteredMatch(for: filename)
        var bestOverride: SourceFormatOverride?
        for override in overrides where filename.hasSuffix(override.suffix) {
            guard bestOverride.map({ override.suffix.count > $0.suffix.count }) ?? true else {
                continue
            }
            bestOverride = override
        }
        let overrideMatch = bestOverride.flatMap { override in
            let registration: SourceFormatRegistration?
            if let format = override.target.format {
                registration = registrations.first(where: { $0.format == format })
            } else {
                registration = automaticRegistration
            }
            return registration.map {
                SourceFormatMatch(
                    registration: $0,
                    filenameSuffix: override.suffix
                )
            }
        }
        guard let overrideMatch else {
            return builtInMatch
        }
        guard let builtInMatch,
              builtInMatch.filenameSuffix.count > overrideMatch.filenameSuffix.count else {
            return overrideMatch
        }
        return builtInMatch
    }

    private func longestRegisteredMatch(for filename: String) -> SourceFormatMatch? {
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

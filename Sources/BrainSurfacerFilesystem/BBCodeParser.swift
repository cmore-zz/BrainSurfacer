import BrainSurfacerModel
import CryptoKit
import Foundation

public struct BBCodeParser: SourceDocumentParser, Sendable {
    public static let outputRevision = 1

    public init() {}

    public var outputRevision: Int {
        Self.outputRevision
    }

    public func excludesIndexing(_ document: SourceDocument) -> Bool {
        false
    }

    public func parseResult(_ document: SourceDocument) -> SourceDocumentParseResult {
        let lines = sourceLines(in: document.contents)
        let headings = headingOccurrences(in: lines)
        let boundedDocumentSource = bounded(
            document.contents,
            maximumBytes: OutlineParser.maximumDocumentBodyBytes
        )
        let renderedDocument = render(boundedDocumentSource.value)
        let boundedDocument = bounded(
            renderedDocument.text,
            maximumBytes: OutlineParser.maximumDocumentBodyBytes
        )
        let sourceID = EntityID(rawValue: "source:\(document.fileURL.standardizedFileURL.path)")
        var sourceAttributes = identityAttributes(
            observedIdentifier: sourceID,
            fingerprint: documentFingerprint(lines: lines, headings: headings)
        )
        if boundedDocumentSource.wasTruncated || boundedDocument.wasTruncated {
            sourceAttributes["bodyTruncated"] = "true"
        }

        var entities = [
            KnowledgeEntity(
                id: sourceID,
                kind: .note,
                title: document.defaultTitle,
                body: boundedDocument.value.isEmpty ? nil : boundedDocument.value,
                summary: summary(for: boundedDocument.value),
                links: renderedDocument.links,
                source: SourceAnchor(
                    fileURL: document.fileURL,
                    byteOffset: 0,
                    byteLength: document.contents.utf8.count
                ),
                modifiedAt: document.modifiedAt,
                attributes: sourceAttributes
            )
        ]

        var duplicateCounts: [String: Int] = [:]
        for (headingIndex, occurrence) in headings.enumerated() {
            let nextOffset = headings.indices.contains(headingIndex + 1)
                ? headings[headingIndex + 1].lineOffset
                : lines.count
            let rawBody = lines[(occurrence.lineOffset + 1) ..< nextOffset]
                .map(\.text)
                .joined(separator: "\n")
            let boundedBodySource = bounded(
                rawBody,
                maximumBytes: OutlineParser.maximumSectionBodyBytes
            )
            let renderedBody = render(boundedBodySource.value)
            let boundedBody = bounded(
                renderedBody.text,
                maximumBytes: OutlineParser.maximumSectionBodyBytes
            )
            let base = ([document.fileURL.standardizedFileURL.path, occurrence.title])
                .joined(separator: "::")
                .lowercased()
            let duplicate = duplicateCounts[base, default: 0]
            duplicateCounts[base] = duplicate + 1
            let suffix = duplicate == 0 ? "" : "::\(duplicate)"
            let observedIdentifier = EntityID(rawValue: "bbcode-outline:\(base)\(suffix)")
            var attributes = identityAttributes(
                observedIdentifier: observedIdentifier,
                fingerprint: sectionFingerprint(renderedBody.text)
            )
            if boundedBodySource.wasTruncated || boundedBody.wasTruncated {
                attributes["bodyTruncated"] = "true"
            }

            let startByte = lines[occurrence.lineOffset].startByteOffset
            let endByte = nextOffset < lines.count
                ? lines[nextOffset].startByteOffset
                : document.contents.utf8.count
            let endLine = nextOffset == lines.count && lines.last?.text.isEmpty == true
                ? max(occurrence.lineOffset + 1, lines.count - 1)
                : max(occurrence.lineOffset + 1, nextOffset)
            entities.append(
                KnowledgeEntity(
                    id: observedIdentifier,
                    kind: .heading,
                    title: occurrence.title,
                    body: boundedBody.value.isEmpty ? nil : boundedBody.value,
                    summary: summary(for: boundedBody.value),
                    links: renderedBody.links,
                    relationships: [Relationship(kind: .parent, target: sourceID)],
                    source: SourceAnchor(
                        fileURL: document.fileURL,
                        headingPath: [occurrence.title],
                        line: occurrence.lineOffset + 1,
                        column: 1,
                        endLine: endLine,
                        byteOffset: startByte,
                        byteLength: endByte - startByte
                    ),
                    modifiedAt: document.modifiedAt,
                    attributes: attributes
                )
            )
        }

        return SourceDocumentParseResult(
            entities: entities,
            wasExcludedByDocumentMetadata: false
        )
    }

    private func headingOccurrences(in lines: [SourceLine]) -> [HeadingOccurrence] {
        var blockedContainers: [String] = []
        var result: [HeadingOccurrence] = []
        for (offset, line) in lines.enumerated() {
            if blockedContainers.isEmpty,
               let title = standaloneBoldTitle(in: line.text) {
                result.append(HeadingOccurrence(lineOffset: offset, title: title))
            }
            updateBlockedContainers(&blockedContainers, from: line.text)
            if let malformedContainer = malformedBlockedContainerOpening(in: line.text) {
                blockedContainers.append(malformedContainer)
            }
        }
        return result
    }

    private func standaloneBoldTitle(in line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = Expressions.standaloneBold.firstMatch(in: line, range: range),
              let titleRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        let title = render(String(line[titleRange])).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              title.contains(where: { $0.isLetter || $0.isNumber }) else {
            return nil
        }
        return String(title.prefix(OutlineParser.maximumSummaryCharacters))
    }

    private func updateBlockedContainers(
        _ containers: inout [String],
        from line: String
    ) {
        for tag in parsedTags(in: line) {
            if let literal = containers.last,
               Self.literalContainerTags.contains(literal) {
                if tag.isClosing, tag.name == literal {
                    containers.removeLast()
                }
                continue
            }
            guard Self.blockedContainerTags.contains(tag.name) else {
                continue
            }
            if tag.isClosing {
                guard let match = containers.lastIndex(of: tag.name) else {
                    continue
                }
                containers.removeSubrange(match...)
            } else if !tag.isSelfClosing {
                containers.append(tag.name)
            }
        }
    }

    private func malformedBlockedContainerOpening(in line: String) -> String? {
        let normalized = line.trimmingCharacters(in: .whitespaces).lowercased()
        guard normalized.hasPrefix("["), !normalized.contains("]") else {
            return nil
        }
        return Self.blockedContainerTags.first { tag in
            normalized == "[\(tag)"
                || normalized.hasPrefix("[\(tag)=")
                || normalized.hasPrefix("[\(tag) ")
        }
    }

    private func render(_ source: String) -> RenderedBBCode {
        var output = ""
        var links: [URL] = []
        var seenLinks: Set<String> = []
        var listStack: [ListState] = []
        var literalContainers: [String] = []
        var index = source.startIndex

        func appendLink(_ value: String) {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let linkValue: String
            if value.contains("@"), !value.contains("://"), !value.hasPrefix("mailto:") {
                linkValue = "mailto:\(value)"
            } else {
                linkValue = value
            }
            guard let url = URL(string: linkValue),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https", "ftp", "mailto"].contains(scheme),
                  seenLinks.insert(url.absoluteString).inserted else {
                return
            }
            links.append(url)
        }

        func appendLineBreak() {
            guard !output.isEmpty, output.last != "\n" else {
                return
            }
            output.append("\n")
        }

        while index < source.endIndex {
            guard source[index] == "[",
                  let closingBracket = source[index...].firstIndex(of: "]"),
                  !source[index ..< closingBracket].contains(where: {
                      $0 == "\n" || $0 == "\r"
                  }) else {
                output.append(source[index])
                index = source.index(after: index)
                continue
            }
            let afterTag = source.index(after: closingBracket)
            let rawTag = String(source[index ..< afterTag])
            guard let tag = parseTag(rawTag) else {
                output.append(source[index])
                index = source.index(after: index)
                continue
            }

            if let literal = literalContainers.last {
                if tag.isClosing, tag.name == literal {
                    literalContainers.removeLast()
                    appendLineBreak()
                } else {
                    output += rawTag
                }
                index = afterTag
                continue
            }

            guard Self.recognizedTags.contains(tag.name) else {
                output += rawTag
                index = afterTag
                continue
            }

            switch tag.name {
            case "quote":
                if tag.isClosing {
                    appendLineBreak()
                } else {
                    appendLineBreak()
                    if let attribution = quoteAttribution(from: tag.parameter) {
                        output += "Quote from \(attribution):\n"
                    } else {
                        output += "Quote:\n"
                    }
                }
            case "list", "ul", "ol":
                if tag.isClosing {
                    if !listStack.isEmpty {
                        listStack.removeLast()
                    }
                    appendLineBreak()
                } else {
                    appendLineBreak()
                    listStack.append(
                        ListState(
                            ordered: tag.name == "ol"
                                || (tag.name == "list" && isOrderedList(tag.parameter))
                        )
                    )
                }
            case "*", "li":
                guard !tag.isClosing else {
                    break
                }
                appendLineBreak()
                if !listStack.isEmpty, listStack[listStack.count - 1].ordered {
                    output += "\(listStack[listStack.count - 1].nextOrdinal). "
                    listStack[listStack.count - 1].nextOrdinal += 1
                } else {
                    output += "• "
                }
            case "url", "email", "post", "thread":
                if !tag.isClosing, let parameter = tag.parameter {
                    appendLink(parameter)
                }
            case "img":
                if !tag.isClosing {
                    output += "Image: "
                }
            case "video", "youtube":
                if !tag.isClosing {
                    output += "Video: "
                }
            case "code", "php", "html", "noparse":
                if !tag.isClosing {
                    appendLineBreak()
                    literalContainers.append(tag.name)
                }
            case "spoiler":
                if !tag.isClosing {
                    appendLineBreak()
                    output += tag.parameter.map { "Spoiler (\($0)):\n" } ?? "Spoiler:\n"
                } else {
                    appendLineBreak()
                }
            case "br":
                appendLineBreak()
            case "hr":
                appendLineBreak()
                output += "———"
                appendLineBreak()
            case "tr":
                appendLineBreak()
            case "td", "th":
                if !tag.isClosing, !output.isEmpty, output.last != "\n" {
                    output.append("\t")
                }
            default:
                break
            }
            index = afterTag
        }

        let cleaned = cleanedRenderedText(output)
        for value in captures(expression: Expressions.bareURL, group: 1, in: cleaned) {
            appendLink(trimmingTrailingURLPunctuation(value))
        }
        for value in captures(expression: Expressions.bareEmail, group: 1, in: cleaned) {
            appendLink(value)
        }
        return RenderedBBCode(text: cleaned, links: links)
    }

    private func parsedTags(in source: String) -> [ParsedTag] {
        let range = NSRange(source.startIndex..., in: source)
        return Expressions.tag.matches(in: source, range: range).compactMap { match in
            guard let tagRange = Range(match.range, in: source) else {
                return nil
            }
            return parseTag(String(source[tagRange]))
        }
    }

    private func parseTag(_ rawTag: String) -> ParsedTag? {
        guard rawTag.first == "[", rawTag.last == "]" else {
            return nil
        }
        var inner = rawTag.dropFirst().dropLast()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var isClosing = false
        if inner.hasPrefix("/") {
            isClosing = true
            inner.removeFirst()
            inner = inner.trimmingCharacters(in: .whitespaces)
        }
        var isSelfClosing = false
        if inner.hasSuffix("/") {
            isSelfClosing = true
            inner.removeLast()
            inner = inner.trimmingCharacters(in: .whitespaces)
        }
        let pieces = inner.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard let rawName = pieces.first else {
            return nil
        }
        var name = rawName.trimmingCharacters(in: .whitespaces).lowercased()
        if isClosing, name == "spoilera" {
            name = "spoiler"
        }
        guard name == "*" || name.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return nil
        }
        let parameter = pieces.count == 2
            ? pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        return ParsedTag(
            name: name,
            parameter: parameter?.isEmpty == true ? nil : parameter,
            isClosing: isClosing,
            isSelfClosing: isSelfClosing
        )
    }

    private func quoteAttribution(from parameter: String?) -> String? {
        guard var attribution = parameter?.split(separator: ";", maxSplits: 1)
            .first.map(String.init) else {
            return nil
        }
        attribution = attribution.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return attribution.isEmpty ? nil : attribution
    }

    private func isOrderedList(_ parameter: String?) -> Bool {
        guard let marker = parameter?.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) else {
            return false
        }
        return ["1", "a", "i"].contains(marker.lowercased())
    }

    private func cleanedRenderedText(_ source: String) -> String {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "&nbsp;", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
            .replacingOccurrences(of: "&#39;", with: "'", options: .caseInsensitive)
            .replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
            .replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
            .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
        var lines: [String] = []
        var consecutiveEmptyLines = 0
        for rawLine in normalized.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            var line = String(rawLine)
            while let last = line.last, last == " " || last == "\t" {
                line.removeLast()
            }
            if line.isEmpty {
                consecutiveEmptyLines += 1
                if consecutiveEmptyLines > 2 {
                    continue
                }
            } else {
                consecutiveEmptyLines = 0
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }

    private func summary(for text: String) -> String? {
        guard let first = text.split(separator: "\n").first(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else {
            return nil
        }
        let normalized = first.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let sentenceEnd = normalized.firstIndex { ".!?".contains($0) }
        let sentence = sentenceEnd.map { String(normalized[...$0]) } ?? normalized
        if sentence.count <= OutlineParser.maximumSummaryCharacters {
            return sentence
        }
        return String(sentence.prefix(OutlineParser.maximumSummaryCharacters - 1)) + "…"
    }

    private func identityAttributes(
        observedIdentifier: EntityID,
        fingerprint: String
    ) -> [String: String] {
        [
            EntityIdentityMetadata.observedIdentifier: observedIdentifier.rawValue,
            EntityIdentityMetadata.structuralFingerprint: fingerprint
        ]
    }

    private func documentFingerprint(
        lines: [SourceLine],
        headings: [HeadingOccurrence]
    ) -> String {
        let headingOffsets = Set(headings.map(\.lineOffset))
        let identityText = lines.enumerated().map { offset, line in
            headingOffsets.contains(offset)
                ? "heading:1"
                : normalizedContent(render(line.text).text)
        }.joined(separator: "\n")
        return fingerprint("document-v1:bbcode:\(identityText)")
    }

    private func sectionFingerprint(_ body: String) -> String {
        fingerprint("outline-v1:bbcode:\(normalizedContent(body))")
    }

    private func normalizedContent(_ value: String) -> String {
        value.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func bounded(
        _ value: String,
        maximumBytes: Int
    ) -> (value: String, wasTruncated: Bool) {
        guard value.utf8.count > maximumBytes else {
            return (value, false)
        }
        var byteCount = 0
        let prefix = value.prefix { character in
            let count = String(character).utf8.count
            guard byteCount + count <= maximumBytes else {
                return false
            }
            byteCount += count
            return true
        }
        return (String(prefix), true)
    }

    private func sourceLines(in contents: String) -> [SourceLine] {
        let bytes = Array(contents.utf8)
        var lines: [SourceLine] = []
        var lineStart = 0
        var offset = 0
        while offset < bytes.count {
            guard bytes[offset] == 10 || bytes[offset] == 13 else {
                offset += 1
                continue
            }
            lines.append(
                SourceLine(
                    text: String(decoding: bytes[lineStart ..< offset], as: UTF8.self),
                    startByteOffset: lineStart
                )
            )
            if bytes[offset] == 13, offset + 1 < bytes.count, bytes[offset + 1] == 10 {
                offset += 2
            } else {
                offset += 1
            }
            lineStart = offset
        }
        lines.append(
            SourceLine(
                text: String(decoding: bytes[lineStart ..< bytes.count], as: UTF8.self),
                startByteOffset: lineStart
            )
        )
        return lines
    }

    private func captures(
        expression: NSRegularExpression,
        group: Int,
        in text: String
    ) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard group < match.numberOfRanges,
                  let range = Range(match.range(at: group), in: text) else {
                return nil
            }
            return String(text[range])
        }
    }

    private func trimmingTrailingURLPunctuation(_ value: String) -> String {
        var value = value
        while let last = value.last, ".,;:!?".contains(last) {
            value.removeLast()
        }
        return value
    }
}

private extension BBCodeParser {
    static let blockedContainerTags: Set<String> = [
        "quote", "list", "ul", "ol", "code", "php", "html", "noparse"
    ]
    static let literalContainerTags: Set<String> = ["code", "php", "html", "noparse"]
    static let recognizedTags: Set<String> = [
        "*", "b", "br", "center", "code", "color", "email", "font", "highlight",
        "hr", "html", "i", "img", "indent", "left", "li", "list", "mention",
        "noparse", "ol", "php", "post", "quote", "right", "s", "size", "spoiler",
        "strike", "sub", "sup", "table", "td", "th", "thread", "tr", "u", "ul",
        "url", "video", "youtube"
    ]

    enum Expressions {
        static let standaloneBold = expression(
            #"^\s*\[b\](.+)\[/b\]\s*$"#,
            options: [.caseInsensitive]
        )
        static let tag = expression(#"\[(?:/)?(?:[[:alnum:]]+|\*)(?:=[^\]]*)?/?\]"#)
        static let bareURL = expression(#"\b((?:https?|ftp)://[^\s<>\)\]\"]+)"#)
        static let bareEmail = expression(
            #"\b([A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,})\b"#,
            options: [.caseInsensitive]
        )

        private static func expression(
            _ pattern: String,
            options: NSRegularExpression.Options = []
        ) -> NSRegularExpression {
            try! NSRegularExpression(pattern: pattern, options: options)
        }
    }

    struct SourceLine {
        var text: String
        var startByteOffset: Int
    }

    struct HeadingOccurrence {
        var lineOffset: Int
        var title: String
    }

    struct ParsedTag {
        var name: String
        var parameter: String?
        var isClosing: Bool
        var isSelfClosing: Bool
    }

    struct ListState {
        var ordered: Bool
        var nextOrdinal = 1
    }

    struct RenderedBBCode {
        var text: String
        var links: [URL]
    }
}

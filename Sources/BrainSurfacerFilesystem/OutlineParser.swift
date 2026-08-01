import BrainSurfacerModel
import CryptoKit
import Foundation

public struct OutlineParser: Sendable {
    public static let maximumHeadingDepth = 32
    public static let maximumMarkdownHeadingDepth = 6
    public static let maximumSectionBodyBytes = 64 * 1_024
    public static let maximumDocumentBodyBytes = 512 * 1_024
    public static let maximumSummaryCharacters = 240

    public init() {}

    public func parse(_ document: SourceDocument) -> [KnowledgeEntity] {
        let lines = sourceLines(in: document.contents)
        let documentMetadata = documentMetadata(in: lines, format: document.format)
        let sourceID = EntityID(rawValue: "source:\(document.fileURL.standardizedFileURL.path)")
        let boundedDocument = bounded(
            document.contents,
            maximumBytes: Self.maximumDocumentBodyBytes
        )
        var sourceAttributes = identityAttributes(
            observedIdentifier: sourceID,
            fingerprint: documentFingerprint(lines: lines, format: document.format)
        )
        if boundedDocument.wasTruncated {
            sourceAttributes["bodyTruncated"] = "true"
        }
        var entities = [
            KnowledgeEntity(
                id: sourceID,
                kind: .note,
                title: documentMetadata.title
                    ?? document.fileURL.deletingPathExtension().lastPathComponent,
                body: boundedDocument.value,
                summary: summary(for: document.contents, format: document.format),
                tags: documentMetadata.tags,
                links: links(in: document.contents, format: document.format),
                dates: documentMetadata.dates,
                source: SourceAnchor(
                    fileURL: document.fileURL,
                    byteOffset: 0,
                    byteLength: document.contents.utf8.count
                ),
                modifiedAt: document.modifiedAt,
                attributes: sourceAttributes
            )
        ]

        var headingStack: [(level: Int, title: String, id: EntityID)] = []
        var duplicateCounts: [String: Int] = [:]
        let parsedHeadings = lines.indices.compactMap { offset -> HeadingOccurrence? in
            guard var parsed = heading(in: lines[offset].text, format: document.format) else {
                return nil
            }
            if document.format == .org,
               let explicitIdentity = orgExplicitIdentity(after: offset, lines: lines) {
                parsed.explicitIdentity = explicitIdentity
            }
            return HeadingOccurrence(offset: offset, heading: parsed)
        }

        for (headingIndex, occurrence) in parsedHeadings.enumerated() {
            let offset = occurrence.offset
            let heading = occurrence.heading

            while headingStack.last.map({ $0.level >= heading.level }) == true {
                headingStack.removeLast()
            }

            let cleanTitle = heading.title
            let path = headingStack.map(\.title) + [cleanTitle]
            let base = ([document.fileURL.standardizedFileURL.path] + path)
                .joined(separator: "::")
                .lowercased()
            let duplicate = duplicateCounts[base, default: 0]
            duplicateCounts[base] = duplicate + 1
            let suffix = duplicate == 0 ? "" : "::\(duplicate)"
            let observedIdentifier = EntityID(rawValue: "outline:\(base)\(suffix)")
            let identifier: EntityID
            if case let .global(namespace, value) = heading.explicitIdentity {
                identifier = EntityID(rawValue: "\(namespace):\(normalizedIdentifier(value))")
            } else {
                identifier = observedIdentifier
            }
            let parentID = headingStack.last?.id ?? sourceID
            let directContentEnd = parsedHeadings.indices.contains(headingIndex + 1)
                ? parsedHeadings[headingIndex + 1].offset
                : lines.count
            let subtreeEnd = parsedHeadings[(headingIndex + 1)...].first {
                $0.heading.level <= heading.level
            }?.offset ?? lines.count
            let rawSection = lines[(offset + 1) ..< directContentEnd]
                .map(\.text)
                .joined(separator: "\n")
            let sectionBody = searchableSectionBody(
                lines: Array(lines[(offset + 1) ..< directContentEnd]),
                format: document.format
            )
            let boundedBody = bounded(
                sectionBody,
                maximumBytes: Self.maximumSectionBodyBytes
            )

            var attributes = identityAttributes(
                observedIdentifier: observedIdentifier,
                explicitIdentifier: heading.explicitIdentity?.matchingKey,
                fingerprint: headingFingerprint(
                    at: offset,
                    level: heading.level,
                    lines: lines,
                    format: document.format
                )
            )
            if let state = heading.taskState {
                attributes["taskState"] = state
            }
            if boundedBody.wasTruncated {
                attributes["bodyTruncated"] = "true"
            }

            var relationships = [Relationship(kind: .parent, target: parentID)]
            if parentID != sourceID {
                relationships.append(Relationship(kind: .belongsTo, target: sourceID))
            }

            let startByte = lines[offset].startByteOffset
            let endByte = subtreeEnd < lines.count
                ? lines[subtreeEnd].startByteOffset
                : document.contents.utf8.count
            let endLine = subtreeEnd == lines.count && lines.last?.text.isEmpty == true
                ? max(offset + 1, lines.count - 1)
                : max(offset + 1, subtreeEnd)

            entities.append(
                KnowledgeEntity(
                    id: identifier,
                    kind: heading.taskState == nil ? .heading : .task,
                    title: cleanTitle,
                    body: boundedBody.value.isEmpty ? nil : boundedBody.value,
                    summary: summary(for: boundedBody.value, format: document.format),
                    // File-level tags describe every contained section. This
                    // mirrors Org FILETAGS inheritance and makes Markdown
                    // front-matter topics available to section search.
                    tags: heading.tags.union(documentMetadata.tags),
                    links: links(in: sectionBody, format: document.format),
                    dates: dates(in: rawSection, format: document.format),
                    relationships: relationships,
                    source: SourceAnchor(
                        fileURL: document.fileURL,
                        headingPath: path,
                        line: offset + 1,
                        column: 1,
                        endLine: endLine,
                        byteOffset: startByte,
                        byteLength: endByte - startByte,
                        editorIdentifier: heading.explicitIdentity?.value
                    ),
                    modifiedAt: document.modifiedAt,
                    attributes: attributes
                )
            )
            headingStack.append((heading.level, cleanTitle, identifier))
        }

        return entities
    }

    private func heading(
        in line: String,
        format: SourceDocument.Format
    ) -> ParsedHeading? {
        let marker: Character = format == .markdown ? "#" : "*"
        let level = line.prefix(while: { $0 == marker }).count
        let maximumDepth = format == .markdown
            ? Self.maximumMarkdownHeadingDepth
            : Self.maximumHeadingDepth
        guard level > 0, level <= maximumDepth else {
            return nil
        }

        let remainder = line.dropFirst(level)
        guard remainder.first?.isWhitespace == true else {
            return nil
        }

        var title = remainder.trimmingCharacters(in: .whitespaces)
        var tags: Set<String> = []
        var taskState: String?
        var explicitIdentity: ExplicitIdentity?

        if format == .org {
            let words = title.split(separator: " ", maxSplits: 1).map(String.init)
            if let first = words.first, ["TODO", "DONE", "NEXT", "WAITING"].contains(first) {
                taskState = first
                title = words.count > 1 ? words[1] : first
            }

            let fullRange = NSRange(title.startIndex..., in: title)
            if let match = Expressions.orgHeadingTags.firstMatch(
                in: title,
                range: fullRange
            ), let tagRange = Range(match.range, in: title) {
                let tagText = title[tagRange].trimmingCharacters(in: .whitespaces)
                tags = Set(tagText.split(separator: ":").map(String.init))
                title.removeSubrange(tagRange)
            }
        } else if let identifier = markdownExplicitIdentifier(in: &title) {
            explicitIdentity = .local(namespace: "markdown-id", value: identifier)
        }

        return ParsedHeading(
            level: level,
            title: title,
            tags: tags,
            taskState: taskState,
            explicitIdentity: explicitIdentity
        )
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

    private func markdownExplicitIdentifier(in title: inout String) -> String? {
        let components = title.split(whereSeparator: \.isWhitespace)
        guard let final = components.last else {
            return nil
        }

        let token = String(final)
        let identifier: String?
        if token.hasPrefix("^"), token.count > 1 {
            identifier = String(token.dropFirst())
        } else if token.hasPrefix("{#"), token.hasSuffix("}"), token.count > 3 {
            identifier = String(token.dropFirst(2).dropLast())
        } else {
            identifier = nil
        }

        guard let identifier, isValidExplicitIdentifier(identifier) else {
            return nil
        }
        title = components.dropLast().joined(separator: " ")
        return identifier
    }

    private func orgExplicitIdentity(
        after headingOffset: Int,
        lines: [SourceLine]
    ) -> ExplicitIdentity? {
        var offset = headingOffset + 1
        skipOrgPreamble(at: &offset, lines: lines)
        guard offset < lines.count,
              lines[offset].text.trimmingCharacters(in: .whitespaces).uppercased()
                == ":PROPERTIES:" else {
            return nil
        }

        var globalID: String?
        var customID: String?
        offset += 1
        while offset < lines.count {
            let property = lines[offset].text.trimmingCharacters(in: .whitespaces)
            if property.uppercased() == ":END:" {
                break
            }
            if let value = propertyValue(named: "ID", in: property) {
                globalID = value
            } else if let value = propertyValue(named: "CUSTOM_ID", in: property) {
                customID = value
            }
            offset += 1
        }

        if let globalID {
            return .global(namespace: "org-id", value: globalID)
        }
        if let customID {
            return .local(namespace: "org-custom-id", value: customID)
        }
        return nil
    }

    private func propertyValue(named name: String, in line: String) -> String? {
        let prefix = ":\(name):"
        guard line.uppercased().hasPrefix(prefix) else {
            return nil
        }
        let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private func isValidExplicitIdentifier(_ identifier: String) -> Bool {
        Expressions.explicitIdentifier.firstMatch(
            in: identifier,
            range: NSRange(identifier.startIndex..., in: identifier)
        ) != nil
    }

    private func identityAttributes(
        observedIdentifier: EntityID,
        explicitIdentifier: String? = nil,
        fingerprint: String
    ) -> [String: String] {
        var attributes = [
            EntityIdentityMetadata.observedIdentifier: observedIdentifier.rawValue,
            EntityIdentityMetadata.structuralFingerprint: fingerprint
        ]
        if let explicitIdentifier {
            attributes[EntityIdentityMetadata.explicitIdentifier] = explicitIdentifier
        }
        return attributes
    }

    private func documentFingerprint(
        lines: [SourceLine],
        format: SourceDocument.Format
    ) -> String {
        let identityText = lines.map { line in
            if let heading = heading(in: line.text, format: format) {
                return "heading:\(heading.level)"
            }
            return normalizedContent(line.text)
        }.joined(separator: "\n")
        return fingerprint("document-v1:\(format):\(identityText)")
    }

    private func headingFingerprint(
        at headingOffset: Int,
        level: Int,
        lines: [SourceLine],
        format: SourceDocument.Format
    ) -> String {
        var identityLines: [String] = []
        var offset = headingOffset + 1
        while offset < lines.count {
            if let child = heading(in: lines[offset].text, format: format) {
                guard child.level > level else {
                    break
                }
                identityLines.append("heading:\(child.level - level)")
            } else {
                identityLines.append(normalizedContent(lines[offset].text))
            }
            offset += 1
        }
        return fingerprint("outline-v1:\(format):\(identityLines.joined(separator: "\n"))")
    }

    private func normalizedContent(_ value: String) -> String {
        value
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func normalizedIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func skipOrgPreamble(at offset: inout Int, lines: [SourceLine]) {
        while offset < lines.count {
            let line = lines[offset].text.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || isOrgPlanningLine(line) {
                offset += 1
                continue
            }
            break
        }
    }

    private func searchableSectionBody(
        lines: [SourceLine],
        format: SourceDocument.Format
    ) -> String {
        var retained: [String] = []
        var insideDrawer = false

        for sourceLine in lines {
            let line = sourceLine.text
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if format == .org {
                if trimmed.uppercased() == ":PROPERTIES:" {
                    insideDrawer = true
                    continue
                }
                if insideDrawer {
                    if trimmed.uppercased() == ":END:" {
                        insideDrawer = false
                    }
                    continue
                }
                if isOrgPlanningLine(trimmed) || trimmed.hasPrefix("#+") {
                    continue
                }
            }
            retained.append(line)
        }

        return retained.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isOrgPlanningLine(_ line: String) -> Bool {
        Expressions.orgPlanningLine.firstMatch(
            in: line,
            range: NSRange(line.startIndex..., in: line)
        ) != nil
    }

    private func documentMetadata(
        in lines: [SourceLine],
        format: SourceDocument.Format
    ) -> DocumentMetadata {
        switch format {
        case .markdown:
            guard lines.first?.text.trimmingCharacters(in: .whitespaces) == "---",
                  let closingOffset = lines.dropFirst().firstIndex(where: {
                      $0.text.trimmingCharacters(in: .whitespaces) == "---"
                  }) else {
                return DocumentMetadata()
            }
            var metadata = DocumentMetadata()
            for line in lines[1 ..< closingOffset] {
                let value = line.text.trimmingCharacters(in: .whitespaces)
                if let title = metadataValue(named: "title", in: value) {
                    metadata.title = title
                } else if let tags = metadataValue(named: "tags", in: value) {
                    metadata.tags.formUnion(parseTags(tags))
                } else if let date = metadataValue(named: "date", in: value),
                          isValidGregorianDate(date) {
                    metadata.dates.append(KnowledgeDate(kind: .mentioned, rawValue: date))
                }
            }
            return metadata
        case .org:
            var metadata = DocumentMetadata()
            for line in lines {
                let value = line.text.trimmingCharacters(in: .whitespaces)
                if heading(in: value, format: .org) != nil {
                    break
                }
                if value.lowercased().hasPrefix("#+title:") {
                    metadata.title = String(value.dropFirst(8))
                        .trimmingCharacters(in: .whitespaces)
                } else if value.lowercased().hasPrefix("#+filetags:") {
                    metadata.tags.formUnion(
                        parseTags(String(value.dropFirst(11)))
                    )
                }
            }
            return metadata
        }
    }

    private func metadataValue(named name: String, in line: String) -> String? {
        let prefix = "\(name):"
        guard line.lowercased().hasPrefix(prefix) else {
            return nil
        }
        let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private func parseTags(_ value: String) -> Set<String> {
        let unwrapped = value.trimmingCharacters(
            in: CharacterSet(charactersIn: "[] ")
        )
        return Set(
            unwrapped.split { $0 == "," || $0 == ":" || $0.isWhitespace }
                .map(String.init)
                .filter { !$0.isEmpty }
        )
    }

    private func links(
        in text: String,
        format: SourceDocument.Format
    ) -> [URL] {
        let patterns: [(NSRegularExpression, Int, Bool)] = switch format {
        case .markdown:
            [
                (Expressions.markdownLink, 1, false),
                (Expressions.markdownAutolink, 1, false),
                (Expressions.bareURL, 1, true)
            ]
        case .org:
            [
                (Expressions.orgLink, 1, false),
                (Expressions.bareURL, 1, true)
            ]
        }

        var result: [URL] = []
        var seen: Set<String> = []
        for (expression, group, trimsTrailingPunctuation) in patterns {
            for captured in captures(expression: expression, group: group, in: text) {
                let value = trimsTrailingPunctuation
                    ? trimmingTrailingURLPunctuation(captured)
                    : captured
                guard let url = URL(string: value), seen.insert(url.absoluteString).inserted else {
                    continue
                }
                result.append(url)
            }
        }
        return result
    }

    private func dates(
        in text: String,
        format: SourceDocument.Format
    ) -> [KnowledgeDate] {
        let result: [KnowledgeDate]
        switch format {
        case .org:
            result = text.split(separator: "\n").flatMap { sourceLine -> [KnowledgeDate] in
                let line = sourceLine.trimmingCharacters(in: .whitespaces)
                guard isOrgPlanningLine(line) else {
                    return []
                }
                return captures(
                    expression: Expressions.orgDate,
                    groups: [1, 2],
                    in: line
                ).compactMap { values in
                    guard values.count == 2,
                          let kind = KnowledgeDate.Kind(
                              rawValue: values[0].lowercased()
                          ) else {
                        return nil
                    }
                    return KnowledgeDate(kind: kind, rawValue: values[1])
                }
            }
        case .markdown:
            result = captures(
                expression: Expressions.markdownDate,
                group: 0,
                in: text
            )
            .filter(isValidGregorianDate)
            .map { KnowledgeDate(kind: .mentioned, rawValue: $0) }
        }
        return result.reduce(into: []) { unique, value in
            if !unique.contains(value) {
                unique.append(value)
            }
        }
    }

    private func summary(
        for text: String,
        format: SourceDocument.Format
    ) -> String? {
        var value = text
        value = replacing(
            expression: Expressions.markdownLinkLabel,
            in: value,
            template: "$1"
        )
        value = replacing(
            expression: Expressions.orgLinkLabel,
            in: value,
            template: "$1"
        )
        value = replacing(
            expression: Expressions.orgPlainLink,
            in: value,
            template: "$1"
        )

        let candidates = value.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let line = String(line).trimmingCharacters(in: .whitespaces)
                if heading(in: line, format: format) != nil {
                    return ""
                }
                return line
            }
            .filter {
                !$0.isEmpty
                    && $0 != "---"
                    && !$0.hasPrefix(":")
                    && !$0.hasPrefix("#+")
                    && !isOrgPlanningLine($0)
                    && metadataValue(named: "tags", in: $0) == nil
                    && metadataValue(named: "date", in: $0) == nil
                    && metadataValue(named: "title", in: $0) == nil
            }
        guard let first = candidates.first else {
            return nil
        }

        let normalized = first.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let sentenceEnd = normalized.firstIndex { ".!?".contains($0) }
        let sentence = sentenceEnd.map { String(normalized[...$0]) } ?? normalized
        if sentence.count <= Self.maximumSummaryCharacters {
            return sentence
        }
        return String(sentence.prefix(Self.maximumSummaryCharacters - 1)) + "…"
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

    private func captures(
        expression: NSRegularExpression,
        group: Int,
        in text: String
    ) -> [String] {
        captures(expression: expression, groups: [group], in: text).compactMap(\.first)
    }

    private func captures(
        expression: NSRegularExpression,
        groups: [Int],
        in text: String
    ) -> [[String]] {
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            let values = groups.compactMap { group -> String? in
                guard group < match.numberOfRanges,
                      let range = Range(match.range(at: group), in: text) else {
                    return nil
                }
                return String(text[range])
            }
            return values.count == groups.count ? values : nil
        }
    }

    private func replacing(
        expression: NSRegularExpression,
        in text: String,
        template: String
    ) -> String {
        return expression.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    private func trimmingTrailingURLPunctuation(_ value: String) -> String {
        var value = value
        while let last = value.last, ".,;:!?".contains(last) {
            value.removeLast()
        }
        return value
    }

    private func isValidGregorianDate(_ value: String) -> Bool {
        let components = value.prefix(10).split(separator: "-").compactMap {
            Int($0)
        }
        guard components.count == 3 else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return DateComponents(
            calendar: calendar,
            year: components[0],
            month: components[1],
            day: components[2]
        ).isValidDate
    }
}

private extension OutlineParser {
    enum Expressions {
        static let orgHeadingTags = expression(#"\s+:(?:[[:alnum:]_@#%]+:)+$"#)
        static let explicitIdentifier = expression(#"^[[:alnum:]][[:alnum:]_.:-]*$"#)
        static let orgPlanningLine = expression(
            #"^(?:SCHEDULED|DEADLINE|CLOSED):\s*[<\[]"#,
            options: [.caseInsensitive]
        )
        static let markdownLink = expression(
            #"\[[^\]]+\]\(([^\s\)]+)(?:\s+[^\)]*)?\)"#
        )
        static let markdownAutolink = expression(#"<(https?://[^>]+)>"#)
        static let bareURL = expression(#"\b(https?://[^\s<>\)\]]+)"#)
        static let orgLink = expression(#"\[\[([^\]]+)\](?:\[[^\]]*\])?\]"#)
        static let orgDate = expression(
            #"\b(SCHEDULED|DEADLINE|CLOSED):\s*[<\[]([^>\]]+)[>\]]"#,
            options: [.caseInsensitive]
        )
        static let markdownDate = expression(
            #"\b\d{4}-\d{2}-\d{2}(?:[T ][0-9:.-]+(?:Z|[+-][0-9:]+)?)?\b"#,
            options: [.caseInsensitive]
        )
        static let markdownLinkLabel = expression(#"\[([^\]]+)\]\([^\)]+\)"#)
        static let orgLinkLabel = expression(#"\[\[[^\]]+\]\[([^\]]+)\]\]"#)
        static let orgPlainLink = expression(#"\[\[([^\]]+)\]\]"#)

        private static func expression(
            _ pattern: String,
            options: NSRegularExpression.Options = []
        ) -> NSRegularExpression {
            // Every pattern is a source literal covered by parser tests.
            try! NSRegularExpression(pattern: pattern, options: options)
        }
    }

    struct SourceLine {
        var text: String
        var startByteOffset: Int
    }

    struct HeadingOccurrence {
        var offset: Int
        var heading: ParsedHeading
    }

    struct DocumentMetadata {
        var title: String?
        var tags: Set<String> = []
        var dates: [KnowledgeDate] = []
    }

    struct ParsedHeading {
        var level: Int
        var title: String
        var tags: Set<String>
        var taskState: String?
        var explicitIdentity: ExplicitIdentity?
    }

    enum ExplicitIdentity {
        case global(namespace: String, value: String)
        case local(namespace: String, value: String)

        var value: String {
            switch self {
            case let .global(_, value), let .local(_, value):
                value
            }
        }

        var matchingKey: String {
            switch self {
            case let .global(namespace, value), let .local(namespace, value):
                "\(namespace):\(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
            }
        }
    }
}

import Foundation

struct SourceFormatDetection: Equatable, Sendable {
    let format: SourceDocument.Format
    let score: Int
    let runnerUpScore: Int
}

struct SourceFormatDetector: Sendable {
    static let outputRevision = 1
    static let maximumInspectedBytes = 128 * 1_024

    let minimumScore: Int
    let minimumLead: Int

    init(minimumScore: Int = 5, minimumLead: Int = 2) {
        self.minimumScore = minimumScore
        self.minimumLead = minimumLead
    }

    func detect(in contents: String) -> SourceFormatDetection? {
        let sample = String(
            decoding: contents.utf8.prefix(Self.maximumInspectedBytes),
            as: UTF8.self
        )
        let lines = sample.components(separatedBy: .newlines)
        let scores: [(SourceDocument.Format, Int)] = [
            (.markdown, markdownScore(lines: lines)),
            (.org, orgScore(lines: lines)),
            (.bbcode, bbcodeScore(lines: lines))
        ].sorted {
            if $0.1 != $1.1 {
                return $0.1 > $1.1
            }
            return $0.0.rawValue < $1.0.rawValue
        }
        guard let winner = scores.first else {
            return nil
        }
        let runnerUpScore = scores.dropFirst().first?.1 ?? 0
        guard winner.1 >= minimumScore,
              winner.1 - runnerUpScore >= minimumLead else {
            return nil
        }
        return SourceFormatDetection(
            format: winner.0,
            score: winner.1,
            runnerUpScore: runnerUpScore
        )
    }

    private func markdownScore(lines: [String]) -> Int {
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        let headingCount = trimmed.filter(isMarkdownHeading).count
        var score = headingCount == 1 ? 2 : min(headingCount, 3) * 3

        let fenceCount = trimmed.filter {
            $0.hasPrefix("```") || $0.hasPrefix("~~~")
        }.count
        if fenceCount >= 2 {
            score += 5
        } else if fenceCount == 1 {
            score += 1
        }

        if let first = trimmed.firstIndex(where: { !$0.isEmpty }),
           trimmed[first] == "---",
           trimmed.dropFirst(first + 1).prefix(80).contains("---") {
            score += 5
        }

        let setextCount = lines.indices.dropLast().filter { index in
            !trimmed[index].isEmpty && isSetextUnderline(trimmed[index + 1])
        }.count
        score += min(setextCount, 2) * 3

        let linkCount = trimmed.filter { line in
            line.contains("](") && line.contains("[")
        }.count
        score += min(linkCount, 2) * 2

        let listCount = trimmed.filter {
            $0.hasPrefix("- ") || $0.hasPrefix("+ ")
        }.count
        if listCount >= 3 {
            score += 1
        }
        return score
    }

    private func orgScore(lines: [String]) -> Int {
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        let uppercased = trimmed.map { $0.uppercased() }
        var score = uppercased.contains(where: { $0.hasPrefix("#+TITLE:") }) ? 6 : 0

        let keywordCount = uppercased.filter {
            $0.hasPrefix("#+") && !$0.hasPrefix("#+TITLE:")
        }.count
        score += min(keywordCount, 2) * 2

        if uppercased.contains(":PROPERTIES:") && uppercased.contains(":END:") {
            score += 5
        }
        if uppercased.contains(where: { $0.hasPrefix("#+BEGIN_SRC") })
            && uppercased.contains("#+END_SRC") {
            score += 6
        }
        if uppercased.contains(where: {
            $0.hasPrefix("SCHEDULED:") || $0.hasPrefix("DEADLINE:")
        }) {
            score += 3
        }

        let headingDepths = trimmed.compactMap(orgHeadingDepth)
        if headingDepths.count >= 2 && headingDepths.contains(where: { $0 > 1 }) {
            score += 5
        } else if headingDepths.count == 2 {
            score += 2
        } else if headingDepths.count == 1 {
            score += 1
        }

        if trimmed.contains(where: { $0.contains("[[") && $0.contains("]]") }) {
            score += 3
        }
        return score
    }

    private func bbcodeScore(lines: [String]) -> Int {
        let lowercased = lines.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        let document = lowercased.joined(separator: "\n")
        var score = min(lowercased.filter(isStandaloneBoldLine).count, 2) * 6

        let structuralTags = ["quote", "code", "list", "url", "img", "spoiler", "table"]
        for tag in structuralTags where hasOpeningBBCodeTag(tag, in: document)
            && document.contains("[/\(tag)]") {
            score += 5
        }

        let formattingTags = ["b", "i", "u", "s", "color", "size", "font"]
        let inlinePairCount = formattingTags.filter { tag in
            hasOpeningBBCodeTag(tag, in: document)
                && document.contains("[/\(tag)]")
                && (tag != "b" || !lowercased.contains(where: isStandaloneBoldLine))
        }.count
        score += min(inlinePairCount, 3)
        return score
    }

    private func isMarkdownHeading(_ line: String) -> Bool {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1 ... 6).contains(hashes), line.count > hashes else {
            return false
        }
        let separator = line[line.index(line.startIndex, offsetBy: hashes)]
        return separator == " " || separator == "\t"
    }

    private func isSetextUnderline(_ line: String) -> Bool {
        guard line.count >= 3, let first = line.first, first == "=" || first == "-" else {
            return false
        }
        return line.allSatisfy { $0 == first }
    }

    private func orgHeadingDepth(_ line: String) -> Int? {
        let depth = line.prefix { $0 == "*" }.count
        guard depth > 0, line.count > depth else {
            return nil
        }
        let separator = line[line.index(line.startIndex, offsetBy: depth)]
        return separator == " " || separator == "\t" ? depth : nil
    }

    private func isStandaloneBoldLine(_ line: String) -> Bool {
        guard line.hasPrefix("[b]"), line.hasSuffix("[/b]") else {
            return false
        }
        return line.dropFirst(3).dropLast(4).contains(where: { !$0.isWhitespace })
    }

    private func hasOpeningBBCodeTag(_ tag: String, in line: String) -> Bool {
        line.contains("[\(tag)]") || line.contains("[\(tag)=")
    }
}

struct AutomaticSourceDocumentParser: SourceDocumentParser, Sendable {
    let registrations: [SourceFormatRegistration]
    let detector: SourceFormatDetector

    var outputRevision: Int {
        registrations.sorted { $0.parserIdentifier < $1.parserIdentifier }.reduce(
            SourceFormatDetector.outputRevision
        ) { revision, registration in
            var combined = revision &* 31 &+ registration.parserRevision
            for byte in registration.parserIdentifier.utf8 {
                combined = combined &* 31 &+ Int(byte)
            }
            for byte in registration.format.rawValue.utf8 {
                combined = combined &* 31 &+ Int(byte)
            }
            return combined
        }
    }

    func parseResult(_ document: SourceDocument) throws -> SourceDocumentParseResult {
        guard let detected = detectedDocument(from: document) else {
            return SourceDocumentParseResult(
                entities: [],
                wasExcludedByDocumentMetadata: false,
                wasSkippedByFormatDetection: true
            )
        }
        return try detected.registration.parseResult(detected.document)
    }

    func excludesIndexing(_ document: SourceDocument) -> Bool {
        guard let detected = detectedDocument(from: document) else {
            return false
        }
        return detected.registration.excludesIndexing(detected.document)
    }

    private func detectedDocument(
        from document: SourceDocument
    ) -> (registration: SourceFormatRegistration, document: SourceDocument)? {
        guard let detection = detector.detect(in: document.contents),
              let registration = registrations.first(where: {
                  $0.format == detection.format
              }) else {
            return nil
        }
        return (
            registration,
            SourceDocument(
                fileURL: document.fileURL,
                format: detection.format,
                filenameSuffix: document.filenameSuffix,
                contents: document.contents,
                modifiedAt: document.modifiedAt
            )
        )
    }
}

import BrainSurfacerModel
import CryptoKit
import Foundation

public struct OutlineParser: Sendable {
    public init() {}

    public func parse(_ document: SourceDocument) -> [KnowledgeEntity] {
        let lines = sourceLines(in: document.contents)
        let sourceID = EntityID(rawValue: "source:\(document.fileURL.standardizedFileURL.path)")
        let sourceAttributes = identityAttributes(
            observedIdentifier: sourceID,
            fingerprint: documentFingerprint(lines: lines, format: document.format)
        )
        var entities = [
            KnowledgeEntity(
                id: sourceID,
                kind: .note,
                title: document.fileURL.deletingPathExtension().lastPathComponent,
                body: document.contents,
                source: SourceAnchor(fileURL: document.fileURL),
                modifiedAt: document.modifiedAt,
                attributes: sourceAttributes
            )
        ]

        var headingStack: [(level: Int, title: String, id: EntityID)] = []
        var duplicateCounts: [String: Int] = [:]

        for (offset, line) in lines.enumerated() {
            guard var heading = heading(in: line, format: document.format) else {
                continue
            }

            if document.format == .org,
               let explicitIdentity = orgExplicitIdentity(after: offset, lines: lines) {
                heading.explicitIdentity = explicitIdentity
            }

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

            entities.append(
                KnowledgeEntity(
                    id: identifier,
                    kind: heading.taskState == nil ? .heading : .task,
                    title: cleanTitle,
                    tags: heading.tags,
                    relationships: [
                        Relationship(kind: .parent, target: parentID)
                    ],
                    source: SourceAnchor(
                        fileURL: document.fileURL,
                        headingPath: path,
                        line: offset + 1,
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
        guard level > 0 else {
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

            if let tagRange = title.range(
                of: #"\s+:(?:[[:alnum:]_@#%]+:)+$"#,
                options: .regularExpression
            ) {
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

    private func sourceLines(in contents: String) -> [String] {
        contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
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
        lines: [String]
    ) -> ExplicitIdentity? {
        var offset = headingOffset + 1
        while offset < lines.count, lines[offset].trimmingCharacters(in: .whitespaces).isEmpty {
            offset += 1
        }
        guard offset < lines.count,
              lines[offset].trimmingCharacters(in: .whitespaces).uppercased() == ":PROPERTIES:" else {
            return nil
        }

        var globalID: String?
        var customID: String?
        offset += 1
        while offset < lines.count {
            let property = lines[offset].trimmingCharacters(in: .whitespaces)
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
        identifier.range(
            of: #"^[[:alnum:]][[:alnum:]_.:-]*$"#,
            options: .regularExpression
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
        lines: [String],
        format: SourceDocument.Format
    ) -> String {
        let identityText = lines.map { line in
            if let heading = heading(in: line, format: format) {
                return "heading:\(heading.level)"
            }
            return normalizedContent(line)
        }.joined(separator: "\n")
        return fingerprint("document-v1:\(format):\(identityText)")
    }

    private func headingFingerprint(
        at headingOffset: Int,
        level: Int,
        lines: [String],
        format: SourceDocument.Format
    ) -> String {
        var identityLines: [String] = []
        var offset = headingOffset + 1
        while offset < lines.count {
            if let child = heading(in: lines[offset], format: format) {
                guard child.level > level else {
                    break
                }
                identityLines.append("heading:\(child.level - level)")
            } else {
                identityLines.append(normalizedContent(lines[offset]))
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
}

private extension OutlineParser {
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

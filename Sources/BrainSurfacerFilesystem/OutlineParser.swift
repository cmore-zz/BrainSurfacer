import BrainSurfacerModel
import Foundation

public struct OutlineParser: Sendable {
    public init() {}

    public func parse(_ document: SourceDocument) -> [KnowledgeEntity] {
        let sourceID = EntityID(rawValue: "source:\(document.fileURL.standardizedFileURL.path)")
        var entities = [
            KnowledgeEntity(
                id: sourceID,
                kind: .note,
                title: document.fileURL.deletingPathExtension().lastPathComponent,
                body: document.contents,
                source: SourceAnchor(fileURL: document.fileURL),
                modifiedAt: document.modifiedAt
            )
        ]

        var headingStack: [(level: Int, title: String, id: EntityID)] = []
        var duplicateCounts: [String: Int] = [:]

        for (offset, rawLine) in document.contents.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ).enumerated() {
            guard let heading = heading(in: String(rawLine), format: document.format) else {
                continue
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
            let identifier = EntityID(rawValue: "outline:\(base)\(suffix)")
            let parentID = headingStack.last?.id ?? sourceID

            var attributes: [String: String] = [:]
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
                        line: offset + 1
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
    ) -> (level: Int, title: String, tags: Set<String>, taskState: String?)? {
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
        }

        return (level, title, tags, taskState)
    }
}

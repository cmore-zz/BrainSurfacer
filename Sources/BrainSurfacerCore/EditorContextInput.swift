import Foundation

/// A connector-friendly JSON representation of an editor's current working set.
///
/// This intentionally differs from `EditorContextUpdate`'s wire encoding: paths
/// are grouped by relevance, timestamps are assigned when the command runs, and
/// relative paths can be resolved beside the input file.
public struct EditorContextInput: Codable, Equatable, Sendable {
    public static let maximumJSONBytes = 65_536

    public enum Error: LocalizedError, Equatable {
        case payloadTooLarge
        case emptyPath

        public var errorDescription: String? {
            switch self {
            case .payloadTooLarge:
                "The editor-context JSON file is too large."
            case .emptyPath:
                "Editor-context paths cannot be empty."
            }
        }
    }

    public var providerID: String
    public var timeToLive: TimeInterval
    public var selected: [String]
    public var visible: [String]
    public var open: [String]

    public init(
        providerID: String,
        timeToLive: TimeInterval = EditorContextUpdate.defaultTimeToLive,
        selected: [String] = [],
        visible: [String] = [],
        open: [String] = []
    ) {
        self.providerID = providerID
        self.timeToLive = timeToLive
        self.selected = selected
        self.visible = visible
        self.open = open
    }

    public func update(
        relativeTo baseDirectory: URL,
        observedAt: Date = Date()
    ) throws -> EditorContextUpdate {
        guard (selected + visible + open).allSatisfy({ !$0.isEmpty }) else {
            throw Error.emptyPath
        }
        let baseDirectory = baseDirectory.standardizedFileURL
        return try EditorContextUpdate(
            providerID: providerID,
            observedAt: observedAt,
            timeToLive: timeToLive,
            documents: documents(
                at: selected,
                relevance: .selected,
                relativeTo: baseDirectory
            ) + documents(
                at: visible,
                relevance: .visible,
                relativeTo: baseDirectory
            ) + documents(
                at: open,
                relevance: .open,
                relativeTo: baseDirectory
            )
        )
    }

    public static func decodeJSON(_ data: Data) throws -> Self {
        guard data.count <= maximumJSONBytes else {
            throw Error.payloadTooLarge
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try values.decode(String.self, forKey: .providerID)
        timeToLive = try values.decodeIfPresent(
            TimeInterval.self,
            forKey: .timeToLive
        ) ?? EditorContextUpdate.defaultTimeToLive
        selected = try values.decodeIfPresent(
            [String].self,
            forKey: .selected
        ) ?? []
        visible = try values.decodeIfPresent(
            [String].self,
            forKey: .visible
        ) ?? []
        open = try values.decodeIfPresent(
            [String].self,
            forKey: .open
        ) ?? []
    }

    private func documents(
        at paths: [String],
        relevance: ContextRelevance,
        relativeTo baseDirectory: URL
    ) -> [EditorContextDocument] {
        paths.map { path in
            EditorContextDocument(
                fileURL: URL(
                    fileURLWithPath: path,
                    relativeTo: baseDirectory
                ).standardizedFileURL,
                relevance: relevance
            )
        }
    }
}

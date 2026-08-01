import Foundation

public struct KnowledgeEntity: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case note
        case heading
        case section
        case block
        case person
        case organization
        case location
        case email
        case url
        case tag
        case project
        case task
    }

    public var id: EntityID
    public var kind: Kind
    public var title: String
    public var body: String?
    public var summary: String?
    public var tags: Set<String>
    public var links: [URL]
    public var dates: [KnowledgeDate]
    public var relationships: [Relationship]
    public var source: SourceAnchor
    public var modifiedAt: Date?
    public var attributes: [String: String]

    public init(
        id: EntityID,
        kind: Kind,
        title: String,
        body: String? = nil,
        summary: String? = nil,
        tags: Set<String> = [],
        links: [URL] = [],
        dates: [KnowledgeDate] = [],
        relationships: [Relationship] = [],
        source: SourceAnchor,
        modifiedAt: Date? = nil,
        attributes: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.summary = summary
        self.tags = tags
        self.links = links
        self.dates = dates
        self.relationships = relationships
        self.source = source
        self.modifiedAt = modifiedAt
        self.attributes = attributes
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case body
        case summary
        case tags
        case links
        case dates
        case relationships
        case source
        case modifiedAt
        case attributes
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(EntityID.self, forKey: .id)
        kind = try values.decode(Kind.self, forKey: .kind)
        title = try values.decode(String.self, forKey: .title)
        body = try values.decodeIfPresent(String.self, forKey: .body)
        summary = try values.decodeIfPresent(String.self, forKey: .summary)
        tags = try values.decodeIfPresent(Set<String>.self, forKey: .tags) ?? []
        links = try values.decodeIfPresent([URL].self, forKey: .links) ?? []
        dates = try values.decodeIfPresent([KnowledgeDate].self, forKey: .dates) ?? []
        relationships = try values.decodeIfPresent(
            [Relationship].self,
            forKey: .relationships
        ) ?? []
        source = try values.decode(SourceAnchor.self, forKey: .source)
        modifiedAt = try values.decodeIfPresent(Date.self, forKey: .modifiedAt)
        attributes = try values.decodeIfPresent(
            [String: String].self,
            forKey: .attributes
        ) ?? [:]
    }
}

public struct KnowledgeDate: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case scheduled
        case deadline
        case closed
        case mentioned
    }

    public var kind: Kind
    /// Source spelling is retained because Org timestamps may be floating,
    /// repeating, or otherwise unsafe to collapse into an absolute `Date`.
    public var rawValue: String

    public init(kind: Kind, rawValue: String) {
        self.kind = kind
        self.rawValue = rawValue
    }
}

public struct Relationship: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case parent
        case child
        case linksTo
        case mentions
        case belongsTo
        case attachedTo
    }

    public var kind: Kind
    public var target: EntityID

    public init(kind: Kind, target: EntityID) {
        self.kind = kind
        self.target = target
    }
}

public struct SourceAnchor: Codable, Hashable, Sendable {
    public var fileURL: URL
    public var headingPath: [String]
    public var line: Int?
    public var column: Int?
    /// Inclusive, one-based final line of the complete anchored subtree.
    public var endLine: Int?
    /// Zero-based UTF-8 range into the source bytes; `byteLength` is half-open.
    public var byteOffset: Int?
    public var byteLength: Int?
    public var editorIdentifier: String?

    public init(
        fileURL: URL,
        headingPath: [String] = [],
        line: Int? = nil,
        column: Int? = nil,
        endLine: Int? = nil,
        byteOffset: Int? = nil,
        byteLength: Int? = nil,
        editorIdentifier: String? = nil
    ) {
        self.fileURL = fileURL
        self.headingPath = headingPath
        self.line = line
        self.column = column
        self.endLine = endLine
        self.byteOffset = byteOffset
        self.byteLength = byteLength
        self.editorIdentifier = editorIdentifier
    }
}

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
        self.relationships = relationships
        self.source = source
        self.modifiedAt = modifiedAt
        self.attributes = attributes
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
    public var editorIdentifier: String?

    public init(
        fileURL: URL,
        headingPath: [String] = [],
        line: Int? = nil,
        column: Int? = nil,
        editorIdentifier: String? = nil
    ) {
        self.fileURL = fileURL
        self.headingPath = headingPath
        self.line = line
        self.column = column
        self.editorIdentifier = editorIdentifier
    }
}

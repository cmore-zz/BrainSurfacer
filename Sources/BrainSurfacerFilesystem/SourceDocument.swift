import Foundation

public struct SourceDocument: Sendable {
    public enum Format: String, Sendable {
        case markdown
        case org
    }

    public var fileURL: URL
    public var format: Format
    public var contents: String
    public var modifiedAt: Date?

    public init(
        fileURL: URL,
        format: Format,
        contents: String,
        modifiedAt: Date? = nil
    ) {
        self.fileURL = fileURL
        self.format = format
        self.contents = contents
        self.modifiedAt = modifiedAt
    }
}

import Foundation

public struct SourceDocument: Sendable {
    public enum Format: String, CaseIterable, Codable, Sendable {
        case markdown
        case org
        case bbcode
    }

    public var fileURL: URL
    public var format: Format
    public var filenameSuffix: String?
    public var contents: String
    public var modifiedAt: Date?

    public init(
        fileURL: URL,
        format: Format,
        filenameSuffix: String? = nil,
        contents: String,
        modifiedAt: Date? = nil
    ) {
        self.fileURL = fileURL
        self.format = format
        self.filenameSuffix = filenameSuffix
        self.contents = contents
        self.modifiedAt = modifiedAt
    }

    public var defaultTitle: String {
        guard let filenameSuffix,
              fileURL.lastPathComponent.lowercased().hasSuffix(filenameSuffix.lowercased()) else {
            return fileURL.deletingPathExtension().lastPathComponent
        }
        return String(fileURL.lastPathComponent.dropLast(filenameSuffix.count))
    }
}

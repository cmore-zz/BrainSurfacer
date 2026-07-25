import Foundation

public struct EntitySearchResult: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var summary: String?
    public var sourceURL: URL?

    public init(
        id: String,
        title: String,
        summary: String? = nil,
        sourceURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.sourceURL = sourceURL
    }
}

public protocol EntitySearch: Sendable {
    func search(_ text: String, limit: Int) async throws -> [EntitySearchResult]
}

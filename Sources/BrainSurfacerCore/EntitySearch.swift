import BrainSurfacerModel
import Foundation

public struct EntitySearchResult: Equatable, Identifiable, Sendable {
    public var id: String
    public var entityID: EntityID?
    public var title: String
    public var summary: String?
    public var sourceURL: URL?

    public init(
        id: String,
        entityID: EntityID? = nil,
        title: String,
        summary: String? = nil,
        sourceURL: URL? = nil
    ) {
        self.id = id
        self.entityID = entityID
        self.title = title
        self.summary = summary
        self.sourceURL = sourceURL
    }
}

public protocol EntitySearch: Sendable {
    func search(_ text: String, limit: Int) async throws -> [EntitySearchResult]
}

/// Searches the durable local catalog independently of platform enrollment.
public struct CatalogEntitySearch: EntitySearch {
    private let catalog: any EntityCatalog

    public init(catalog: any EntityCatalog) {
        self.catalog = catalog
    }

    public func search(
        _ text: String,
        limit: Int = 20
    ) async throws -> [EntitySearchResult] {
        let query = Self.normalized(text)
        guard !query.isEmpty, limit > 0 else {
            return []
        }
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return try await catalog.allEntities().compactMap { entity in
            Self.match(entity, query: query, tokens: tokens)
        }
        .sorted {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            if $0.entity.title != $1.entity.title {
                return $0.entity.title.localizedStandardCompare($1.entity.title)
                    == .orderedAscending
            }
            return $0.entity.id.rawValue < $1.entity.id.rawValue
        }
        .prefix(limit)
        .map { match in
            EntitySearchResult(
                id: "catalog:\(match.entity.id.rawValue)",
                entityID: match.entity.id,
                title: match.entity.title,
                summary: match.entity.summary,
                sourceURL: match.entity.source.fileURL
            )
        }
    }

    private static func match(
        _ entity: KnowledgeEntity,
        query: String,
        tokens: [String]
    ) -> CatalogSearchMatch? {
        let title = normalized(entity.title)
        let tags = entity.tags.map(normalized)
        let summary = normalized(entity.summary ?? "")
        let body = normalized(entity.body ?? "")
        let path = normalized(entity.source.fileURL.path(percentEncoded: false))
        let searchable = ([title, summary, body, path] + tags)
            .joined(separator: " ")
        guard tokens.allSatisfy(searchable.contains) else {
            return nil
        }

        var score = 0
        if title == query {
            score += 1_000
        } else if title.hasPrefix(query) {
            score += 500
        } else if title.contains(query) {
            score += 250
        }
        score += tokens.filter(title.contains).count * 100
        score += tokens.filter { token in tags.contains(token) }.count * 80
        score += tokens.filter(summary.contains).count * 40
        score += tokens.filter(body.contains).count * 20
        score += tokens.filter(path.contains).count * 10
        return CatalogSearchMatch(entity: entity, score: score)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }
}

/// Combines local discovery with optional platform-ranked results while
/// deduplicating their shared canonical entities.
public struct MergedEntitySearch: EntitySearch {
    private let searches: [any EntitySearch]

    public init(searches: [any EntitySearch]) {
        self.searches = searches
    }

    public func search(
        _ text: String,
        limit: Int = 20
    ) async throws -> [EntitySearchResult] {
        guard limit > 0 else {
            return []
        }
        var merged: [EntitySearchResult] = []
        var seen: Set<String> = []
        var firstError: (any Error)?
        var successfulSearchCount = 0

        for search in searches {
            do {
                let results = try await search.search(text, limit: limit)
                successfulSearchCount += 1
                for result in results {
                    let identity = result.entityID?.rawValue ?? result.id
                    guard seen.insert(identity).inserted else {
                        continue
                    }
                    merged.append(result)
                    if merged.count == limit {
                        return merged
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if successfulSearchCount == 0, let firstError {
            throw firstError
        }
        return merged
    }
}

private struct CatalogSearchMatch {
    var entity: KnowledgeEntity
    var score: Int
}

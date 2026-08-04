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

/// Searches entities kept exclusively in the local catalog.
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
        return try await catalog.locallyOnlyEntities().compactMap { entity in
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
        var resultSets: [[EntitySearchResult]] = []
        var firstError: (any Error)?

        for search in searches {
            do {
                let results = try await search.search(text, limit: limit)
                resultSets.append(results)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if resultSets.isEmpty, let firstError {
            throw firstError
        }

        // Results from different ranking systems have no comparable score.
        // Preserve each backend's order and interleave them so neither a full
        // Spotlight page nor a full local-only page starves the other.
        var merged: [EntitySearchResult] = []
        var seen: Set<String> = []
        var offsets = Array(repeating: 0, count: resultSets.count)
        while merged.count < limit {
            var appendedResult = false
            for index in resultSets.indices {
                while offsets[index] < resultSets[index].count {
                    let result = resultSets[index][offsets[index]]
                    offsets[index] += 1
                    let identity = result.entityID?.rawValue ?? result.id
                    guard seen.insert(identity).inserted else {
                        continue
                    }
                    merged.append(result)
                    appendedResult = true
                    break
                }
                if merged.count == limit {
                    break
                }
            }
            if !appendedResult {
                break
            }
        }
        return merged
    }
}

private struct CatalogSearchMatch {
    var entity: KnowledgeEntity
    var score: Int
}

/// Applies ephemeral working context without replacing a search backend's
/// relevance ranking. Context only reorders results that the query already
/// matched, and base order remains stable among equal context scores.
public struct ContextualSearchReranker: Sendable {
    public init() {}

    public func rerank(
        _ results: [EntitySearchResult],
        using context: CurrentContext
    ) -> [EntitySearchResult] {
        let contextScores = Dictionary(
            context.resolved.map { ($0.entity.id, $0.score) },
            uniquingKeysWith: max
        )
        return results.enumerated().sorted { first, second in
            let firstScore = first.element.entityID
                .flatMap { contextScores[$0] } ?? 0
            let secondScore = second.element.entityID
                .flatMap { contextScores[$0] } ?? 0
            if firstScore != secondScore {
                return firstScore > secondScore
            }
            return first.offset < second.offset
        }.map(\.element)
    }
}

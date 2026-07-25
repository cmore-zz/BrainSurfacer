import BrainSurfacerCore
@preconcurrency import CoreSpotlight
import Foundation

public struct SpotlightEntitySearch: EntitySearch {
    private static let prepareOnce: Void = CSUserQuery.prepare()

    public init() {
        _ = Self.prepareOnce
    }

    public func search(_ text: String, limit: Int = 20) async throws -> [EntitySearchResult] {
        let searchText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchText.isEmpty, limit > 0 else {
            return []
        }

        let context = CSUserQueryContext()
        context.enableRankedResults = true
        context.maxResultCount = limit
        context.maxRankedResultCount = limit
        context.maxSuggestionCount = 0
        context.fetchAttributes = [
            "title",
            "displayName",
            "contentDescription",
            "contentURL",
            "domainIdentifier"
        ]
        context.filterQueries = [
            "domainIdentifier == \"\(SpotlightKnowledgeEntity.searchDomainIdentifier)\""
        ]

        let query = CSUserQuery(
            userQueryString: searchText,
            userQueryContext: context
        )

        return try await withTaskCancellationHandler {
            var results: [EntitySearchResult] = []
            var seenIdentifiers: Set<String> = []

            for try await response in query.responses {
                try Task.checkCancellation()
                guard case let .item(item) = response else {
                    continue
                }
                guard seenIdentifiers.insert(item.id).inserted else {
                    continue
                }

                results.append(Self.result(from: item.item))
                if results.count == limit {
                    query.cancel()
                    break
                }
            }

            return results
        } onCancel: {
            query.cancel()
        }
    }

    static func result(from item: CSSearchableItem) -> EntitySearchResult {
        let attributes = item.attributeSet
        let sourceURL = attributes.contentURL
        let title = attributes.title
            ?? attributes.displayName
            ?? sourceURL?.deletingPathExtension().lastPathComponent
            ?? "Untitled"

        return EntitySearchResult(
            id: item.uniqueIdentifier,
            title: title,
            summary: attributes.contentDescription,
            sourceURL: sourceURL
        )
    }
}

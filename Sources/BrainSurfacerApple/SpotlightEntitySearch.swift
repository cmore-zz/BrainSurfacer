import BrainSurfacerCore
import BrainSurfacerModel
@preconcurrency import CoreSpotlight
import Foundation

public struct SpotlightEntitySearch: EntitySearch {
    private static let prepareOnce: Void = CSUserQuery.prepare()
    static let searchDomainFilter =
        "(domainIdentifier == \"\(SpotlightKnowledgeEntity.searchDomainIdentifier)\""
        + " || domainIdentifier == \"\(SpotlightNoteEntity.searchDomainIdentifier)\")"

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
            "path",
            "domainIdentifier"
        ]
        context.filterQueries = [
            Self.searchDomainFilter
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
        let deepLink = attributes.contentURL.flatMap {
            BrainSurfacerDeepLink(url: $0)
        }
        let entityID: EntityID?
        if case let .entity(identifier) = deepLink {
            entityID = identifier
        } else {
            entityID = nil
        }
        let sourceURL = attributes.path.map(URL.init(fileURLWithPath:))
            ?? attributes.contentURL.flatMap { $0.isFileURL ? $0 : nil }
        let title = attributes.title
            ?? attributes.displayName
            ?? sourceURL?.deletingPathExtension().lastPathComponent
            ?? "Untitled"

        return EntitySearchResult(
            id: item.uniqueIdentifier,
            entityID: entityID,
            title: title,
            summary: attributes.contentDescription,
            sourceURL: sourceURL
        )
    }
}

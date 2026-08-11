import AppIntents
import BrainSurfacerCore
import BrainSurfacerModel
@preconcurrency import CoreSpotlight
import Foundation
import OSLog
import UniformTypeIdentifiers

private enum SpotlightLiveContextLog {
    static let logger = Logger(
        subsystem: "org.brainsurfacer.BrainSurfacer",
        category: "LiveContextEntityQuery"
    )
}

/// A single, expiring semantic projection of the editor state shared with
/// BrainSurfacer. The aggregate lets system search answer questions such as
/// “what is open?” without turning each context signal into durable knowledge.
public struct SpotlightLiveContextEntity: IndexedEntity {
    public static let currentIdentifier = "brainsurfacer-current-editor-context-v1"
    public static let searchDomainIdentifier = "SpotlightLiveContextEntity"
    public static let defaultQuery = Query()

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Current Editor Context"
    }

    public let id: String
    @Property(indexingKey: \.displayName) public var title: String
    @Property(indexingKey: \.contentDescription) public var summary: String
    @Property(indexingKey: \.textContent) public var text: String
    @Property(indexingKey: \.keywords) public var keywords: [String]
    @Property(indexingKey: \.contentModificationDate) public var observedAt: Date?
    public let expirationDate: Date

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(summary)")
    }

    public var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.contentType = UTType.text.identifier
        attributes.displayName = title
        attributes.contentDescription = summary
        attributes.textContent = text
        attributes.keywords = keywords
        attributes.contentModificationDate = observedAt
        return attributes
    }

    init?(_ context: CurrentContext) {
        let items = Array(context.resolved.prefix(Self.maximumItemCount))
        guard !items.isEmpty,
              let expirationDate = items.flatMap(\.signals).map(\.expiresAt).min() else {
            return nil
        }

        id = Self.currentIdentifier
        self.expirationDate = expirationDate
        title = "Current BrainSurfacer editor context"
        observedAt = items.flatMap(\.signals).map(\.observedAt).max()

        let descriptions = items.map(Self.description)
        summary = Self.bounded(
            "Currently selected, visible, or open in BrainSurfacer: "
                + descriptions.map(\.short).joined(separator: ", ")
                + ".",
            limit: Self.maximumSummaryCharacters
        )
        text = Self.bounded(
            ([
                "This is the current, temporary editor context shared with BrainSurfacer.",
                "The following documents are selected, visible, or open right now:"
            ] + descriptions.map(\.long)).joined(separator: "\n"),
            limit: Self.maximumTextCharacters
        )
        keywords = Array(Set(
            [
                "BrainSurfacer", "current", "editor context", "open", "selected",
                "visible", "working on", "active document", "open files"
            ] + items.flatMap { item in
                [item.entity.title, item.entity.source.fileURL.lastPathComponent]
                    + item.signals.map { $0.relevance.rawValue }
            }
        )).sorted()
    }

    static func searchableItem(for entity: SpotlightLiveContextEntity) -> CSSearchableItem {
        let item = CSSearchableItem(appEntity: entity)
        item.expirationDate = entity.expirationDate
        return item
    }

    private static let maximumItemCount = 20
    private static let maximumExcerptCharacters = 1_000
    private static let maximumSummaryCharacters = 2_000
    private static let maximumTextCharacters = 24_000

    private static func description(
        for item: ResolvedContextItem
    ) -> (short: String, long: String) {
        let relevance = bestRelevance(in: item).rawValue
        let filename = item.entity.source.fileURL.lastPathComponent
        let short = "\(item.entity.title) (\(relevance), \(filename))"
        let excerpt = boundedExcerpt(item.entity.body ?? item.entity.summary)
        let long = "- \(short)" + excerpt.map { ": \($0)" }.orEmpty
        return (short, long)
    }

    private static func bestRelevance(
        in item: ResolvedContextItem
    ) -> ContextRelevance {
        let policy = DefaultContextRankingPolicy()
        return item.signals.max {
            policy.score(for: [$0]) < policy.score(for: [$1])
        }?.relevance ?? .open
    }

    private static func boundedExcerpt(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return bounded(trimmed, limit: maximumExcerptCharacters)
    }

    private static func bounded(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    public struct Query: IndexedEntityQuery {
        public static let persistentIdentifier =
            "brainsurfacer.query.live-editor-context.v1"

        private let snapshotStore: PersistentContextSnapshotStore
        private let catalog: any EntityCatalog

        public init() {
            snapshotStore = PersistentContextSnapshotStore()
            catalog = PersistentEntityCatalog(
                storageURL: PersistentEntityCatalog.defaultStorageURL(),
                accessMode: .readOnly
            )
        }

        init(
            snapshotStore: PersistentContextSnapshotStore,
            catalog: any EntityCatalog
        ) {
            self.snapshotStore = snapshotStore
            self.catalog = catalog
        }

        public func entities(for identifiers: [String]) async throws
            -> [SpotlightLiveContextEntity] {
            SpotlightLiveContextLog.logger.notice(
                "Live-context entity query requested \(identifiers.count, privacy: .public) identifier(s)"
            )
            guard identifiers.contains(SpotlightLiveContextEntity.currentIdentifier) else {
                SpotlightLiveContextLog.logger.debug(
                    "Live-context entity query did not request the current aggregate"
                )
                return []
            }
            guard let entity = try await SpotlightLiveContextResolver.entity(
                snapshotStore: snapshotStore,
                catalog: catalog
            ) else {
                SpotlightLiveContextLog.logger.notice(
                    "Live-context entity query found no unexpired Apple-eligible aggregate"
                )
                return []
            }
            SpotlightLiveContextLog.logger.notice(
                "Live-context entity query resolved the current aggregate"
            )
            return [entity]
        }

        public func reindexEntities(
            for identifiers: [String],
            indexDescription: CSSearchableIndexDescription
        ) async throws {
            guard identifiers.contains(SpotlightLiveContextEntity.currentIdentifier) else {
                return
            }
            try await replaceCurrentItem(in: Self.index(for: indexDescription))
        }

        public func reindexAllEntities(
            indexDescription: CSSearchableIndexDescription
        ) async throws {
            try await replaceCurrentItem(in: Self.index(for: indexDescription))
        }

        private func replaceCurrentItem(in index: CSSearchableIndex) async throws {
            let entity = try await SpotlightLiveContextResolver.entity(
                snapshotStore: snapshotStore,
                catalog: catalog
            )
            try await SpotlightLiveContextDonation.replace(entity, in: index)
        }

        private static func index(
            for description: CSSearchableIndexDescription
        ) -> CSSearchableIndex {
            CSSearchableIndex(
                name: SpotlightEntityIndex.indexName,
                protectionClass: description.protectionClass
            )
        }
    }
}

public actor SpotlightLiveContextIndex: ContextPublisher {
    private let index: CSSearchableIndex
    private let catalog: any EntityCatalog

    public init(
        index: CSSearchableIndex = CSSearchableIndex(name: SpotlightEntityIndex.indexName),
        catalog: any EntityCatalog = PersistentEntityCatalog(
            storageURL: PersistentEntityCatalog.defaultStorageURL(),
            accessMode: .readOnly
        )
    ) {
        self.index = index
        self.catalog = catalog
    }

    public func publish(_ context: CurrentContext) async throws {
        do {
            let entity = try await SpotlightLiveContextResolver.entity(
                from: context,
                catalog: catalog
            )
            try await SpotlightLiveContextDonation.replace(entity, in: index)
        } catch {
            let cocoaError = error as NSError
            guard cocoaError.domain == CSIndexErrorDomain else {
                throw error
            }
            throw SpotlightIndexingError(code: cocoaError.code)
        }
    }
}

private enum SpotlightLiveContextDonation {
    static func replace(
        _ entity: SpotlightLiveContextEntity?,
        in index: CSSearchableIndex
    ) async throws {
        try await index.deleteAppEntities(
            identifiedBy: [SpotlightLiveContextEntity.currentIdentifier],
            ofType: SpotlightLiveContextEntity.self
        )
        if let entity {
            try await index.indexSearchableItems([
                SpotlightLiveContextEntity.searchableItem(for: entity)
            ])
        }
    }
}

enum SpotlightLiveContextResolver {
    static func entity(
        at date: Date = Date(),
        snapshotStore: PersistentContextSnapshotStore,
        catalog: any EntityCatalog
    ) async throws -> SpotlightLiveContextEntity? {
        let coordinator = ContextCoordinator(catalog: catalog)
        for snapshot in await snapshotStore.snapshots(at: date) {
            await coordinator.ingest(snapshot)
        }
        return try await entity(
            from: coordinator.currentContext(at: date),
            catalog: catalog
        )
    }

    static func entity(
        from context: CurrentContext,
        catalog: any EntityCatalog
    ) async throws -> SpotlightLiveContextEntity? {
        let eligibleContext = try await AppleDiscoveryContextFilter.eligibleContext(
            from: context,
            catalog: catalog
        )
        return SpotlightLiveContextEntity(eligibleContext)
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

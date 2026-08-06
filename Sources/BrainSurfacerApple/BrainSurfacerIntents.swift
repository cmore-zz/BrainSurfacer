import AppIntents
import BrainSurfacerCore
import BrainSurfacerModel
import Foundation

public struct OpenSpotlightKnowledgeIntent: OpenIntent {
    public static let title: LocalizedStringResource = "Open Knowledge Item"
    public static let supportedModes: IntentModes = .background

    @Parameter(title: "Knowledge Item") public var target: SpotlightKnowledgeEntity

    public init() {}

    public init(target: SpotlightKnowledgeEntity) {
        self.target = target
    }

    public func perform() async throws -> some IntentResult {
        try await BrainSurfacerIntentOpening.open(target.canonicalEntityID)
        return .result()
    }
}

public struct OpenSpotlightNoteIntent: OpenIntent {
    public static let title: LocalizedStringResource = "Open Note"
    public static let supportedModes: IntentModes = .background

    @Parameter(title: "Note") public var target: SpotlightNoteEntity

    public init() {}

    public init(target: SpotlightNoteEntity) {
        self.target = target
    }

    public func perform() async throws -> some IntentResult {
        try await BrainSurfacerIntentOpening.open(target.canonicalEntityID)
        return .result()
    }
}

@AppIntent(schema: .system.searchInApp)
public struct ShowBrainSurfacerSearchIntent: ShowInAppSearchResultsIntent {
    public static let title: LocalizedStringResource = "Search BrainSurfacer"
    public static let supportedModes: IntentModes = .foreground(.immediate)
    public static let searchScopes: [StringSearchScope] = [.general]

    @Parameter(title: "Search") public var criteria: StringSearchCriteria

    public init() {}

    public init(criteria: StringSearchCriteria) {
        self.criteria = criteria
    }

    public func perform() async throws -> some IntentResult {
        await BrainSurfacerNavigationRequests.submitSearch(criteria.term)
        return .result()
    }
}

@MainActor
public enum BrainSurfacerNavigationRequests {
    public static let didSubmitSearch = Notification.Name(
        "BrainSurfacerDidSubmitSearchRequest"
    )

    private static let pendingSearchKey = "pendingInAppSearch"

    public static func submitSearch(_ term: String) {
        UserDefaults.standard.set(term, forKey: pendingSearchKey)
        NotificationCenter.default.post(name: didSubmitSearch, object: nil)
    }

    public static func consumePendingSearch() -> String? {
        let defaults = UserDefaults.standard
        guard let term = defaults.string(forKey: pendingSearchKey) else {
            return nil
        }
        defaults.removeObject(forKey: pendingSearchKey)
        return term
    }
}

enum BrainSurfacerIntentOpening {
    static func open(_ entityID: EntityID) async throws {
        let catalog = PersistentEntityCatalog(
            storageURL: PersistentEntityCatalog.defaultStorageURL(),
            accessMode: .readOnly
        )
        try await open(
            entityID,
            catalog: catalog,
            openers: [ConfiguredDocumentOpener()]
        )
    }

    static func open(
        _ entityID: EntityID,
        catalog: any EntityCatalog,
        openers: [any DocumentOpener]
    ) async throws {
        let coordinator = EntityOpeningCoordinator(
            catalog: catalog,
            openers: openers
        )
        do {
            try await coordinator.open(.entityID(entityID))
        } catch EntityOpeningError.failureAlreadyPresented(_) {
            // The system-owned UI is the complete result for this invocation;
            // do not make Siri or Shortcuts repeat the same failure.
        }
    }
}

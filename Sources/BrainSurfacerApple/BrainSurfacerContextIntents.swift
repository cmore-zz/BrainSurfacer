import AppIntents
import BrainSurfacerCore
import BrainSurfacerModel
import Foundation

public struct BrainSurfacerContextItemEntity: TransientAppEntity {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Current Document"
    }

    @Property(title: "Title") public var title: String
    @Property(title: "Content Excerpt") public var contentExcerpt: String?
    @Property(title: "Source File") public var sourceURL: URL
    @Property(title: "Relevance") public var relevance: String
    @Property(title: "Context Providers") public var providerIDs: [String]
    @Property(title: "Open URL") public var openURL: URL

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(relevance.capitalized) · \(sourceURL.lastPathComponent)"
        )
    }

    public init() {
        title = ""
        contentExcerpt = nil
        sourceURL = URL(fileURLWithPath: "/")
        relevance = ContextRelevance.open.rawValue
        providerIDs = []
        openURL = URL(fileURLWithPath: "/")
    }

    init(_ item: ResolvedContextItem) {
        let entity = item.entity
        title = entity.title
        contentExcerpt = BrainSurfacerIntentText.excerpt(
            entity.body ?? entity.summary,
            limit: BrainSurfacerIntentText.maximumContextExcerptCharacters
        )
        sourceURL = entity.source.fileURL
        relevance = BrainSurfacerIntentContext.bestRelevance(in: item).rawValue
        providerIDs = Array(Set(item.signals.map(\.providerID))).sorted()
        openURL = BrainSurfacerDeepLink.entity(entity.id).url
    }
}

public struct GetCurrentBrainSurfacerContextIntent: AppIntent {
    public static let title: LocalizedStringResource =
        "Get Current BrainSurfacer Context"
    public static let description: IntentDescription =
        "Returns the selected, visible, and open documents most recently shared with BrainSurfacer by an editor. Live context expires automatically."
    public static let supportedModes: IntentModes = .background

    public init() {}

    public func perform() async throws
        -> some IntentResult
            & ReturnsValue<[BrainSurfacerContextItemEntity]>
            & ProvidesDialog {
        let entities = try await BrainSurfacerIntentContext.entities()
        let summary = BrainSurfacerIntentText.contextDialog(for: entities)
        return .result(value: entities, dialog: "\(summary)")
    }
}

public struct ReadBrainSurfacerNoteIntent: AppIntent {
    public static let title: LocalizedStringResource = "Read BrainSurfacer Note"
    public static let description: IntentDescription =
        "Returns a BrainSurfacer note’s content and source-file path."
    public static let supportedModes: IntentModes = .background

    @Parameter(title: "Note") public var note: SpotlightNoteEntity

    public init() {}

    public init(note: SpotlightNoteEntity) {
        self.note = note
    }

    public static var parameterSummary: some ParameterSummary {
        Summary("Read \(\.$note)")
    }

    public func perform() async throws
        -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let details = BrainSurfacerIntentText.noteDetails(for: note)
        let dialog = BrainSurfacerIntentText.excerpt(
            details,
            limit: BrainSurfacerIntentText.maximumDialogCharacters
        ) ?? "The note is empty."
        return .result(value: details, dialog: "\(dialog)")
    }
}

enum BrainSurfacerIntentContext {
    static let maximumItemCount = 20

    static func entities(
        at date: Date = Date(),
        snapshotStore: PersistentContextSnapshotStore =
            PersistentContextSnapshotStore(),
        catalog: any EntityCatalog = PersistentEntityCatalog(
            storageURL: PersistentEntityCatalog.defaultStorageURL(),
            accessMode: .readOnly
        )
    ) async throws -> [BrainSurfacerContextItemEntity] {
        let coordinator = ContextCoordinator(catalog: catalog)
        for snapshot in await snapshotStore.snapshots(at: date) {
            await coordinator.ingest(snapshot)
        }
        let context = try await AppleDiscoveryContextFilter.eligibleContext(
            from: coordinator.currentContext(at: date),
            catalog: catalog
        )
        return context.resolved.prefix(maximumItemCount).map(
            BrainSurfacerContextItemEntity.init
        )
    }

    static func bestRelevance(
        in item: ResolvedContextItem
    ) -> ContextRelevance {
        item.signals.max {
            score(for: $0.relevance) < score(for: $1.relevance)
        }?.relevance ?? .open
    }

    private static func score(for relevance: ContextRelevance) -> Int {
        DefaultContextRankingPolicy().score(
            for: [
                ContextSignal(
                    providerID: "intent",
                    relevance: relevance,
                    observedAt: .distantPast,
                    expiresAt: .distantFuture
                )
            ]
        )
    }
}

enum BrainSurfacerIntentText {
    static let maximumContextExcerptCharacters = 4_000
    static let maximumReturnedNoteCharacters = 64_000
    static let maximumDialogCharacters = 1_500

    static func excerpt(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

    static func noteDetails(for note: SpotlightNoteEntity) -> String {
        let title = String(note.name.characters)
        let content = excerpt(
            note.readableContent,
            limit: maximumReturnedNoteCharacters
        ) ?? "(No content)"
        return "\(title)\nSource: \(note.sourceFileURL.path)\n\n\(content)"
    }

    static func contextDialog(
        for entities: [BrainSurfacerContextItemEntity]
    ) -> String {
        guard !entities.isEmpty else {
            return "BrainSurfacer has no unexpired editor context right now."
        }
        let names = entities.prefix(8).map {
            "\($0.title) (\($0.relevance))"
        }.joined(separator: ", ")
        let remainder = entities.count - min(entities.count, 8)
        if remainder == 0 {
            return "Current BrainSurfacer context: \(names)."
        }
        return "Current BrainSurfacer context: \(names), and \(remainder) more."
    }
}

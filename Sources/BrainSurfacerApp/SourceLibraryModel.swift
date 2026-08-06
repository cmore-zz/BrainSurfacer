import AppKit
import BrainSurfacerApple
import BrainSurfacerCore
import BrainSurfacerFilesystem
import Foundation
import Observation

struct SourceIndexStatus: Equatable {
    enum State: Equatable {
        case waiting
        case indexing
        case indexed
        case paused
        case failed(String)
    }

    var state: State = .waiting
    var fileCount = 0
    var entityCount = 0
    var diagnosticCount = 0
    var indexedAt: Date?
}

struct SearchPresentationRequest: Equatable, Identifiable {
    let id = UUID()
    let term: String
}

@MainActor
@Observable
final class SourceLibraryModel {
    private(set) var sources: [SourceDirectory] = []
    private(set) var isLoading = true
    private(set) var indexStatusBySource: [String: SourceIndexStatus] = [:]
    private(set) var searchResults: [EntitySearchResult] = []
    private(set) var isSearching = false
    private(set) var searchErrorMessage: String?
    private(set) var searchPresentationRequest: SearchPresentationRequest?
    private(set) var currentContext = CurrentContext(resolved: [], unresolved: [])
    private(set) var contextStatusMessage: String?
    var errorMessage: String?

    private let store: SourceDirectoryStore
    private let coordinator: IndexingCoordinator
    private let reconciler: SourceReconciler
    private let entitySearch: any EntitySearch
    private let openingCoordinator: EntityOpeningCoordinator
    private let contextCoordinator: ContextCoordinator
    private let contextSnapshotStore: PersistentContextSnapshotStore
    private let contextPublisher: any ContextPublisher
    private let sourceObserver: FSEventsSourceObserver
    private var sourceChangeSubscription: SourceChangeSubscription?
    private var sourceObservationTask: Task<Void, Never>?
    private var sourceChangeCoalescer: SourceChangeCoalescer?
    private var searchGeneration = 0

    init(
        store: SourceDirectoryStore = SourceDirectoryStore(),
        scanner: SourceDirectoryScanner = SourceDirectoryScanner(),
        fingerprintStore: SourceFingerprintStore = SourceFingerprintStore(),
        entitySearch: (any EntitySearch)? = nil,
        sourceObserver: FSEventsSourceObserver = FSEventsSourceObserver(),
        contextPublisher: (any ContextPublisher)? = nil
    ) {
        self.store = store
        self.sourceObserver = sourceObserver
        let catalog = PersistentEntityCatalog(
            storageURL: PersistentEntityCatalog.defaultStorageURL(),
            accessMode: .coordinatingWriter
        )
        self.entitySearch = entitySearch ?? MergedEntitySearch(
            searches: [
                SpotlightEntitySearch(),
                CatalogEntitySearch(catalog: catalog)
            ]
        )
        let coordinator = IndexingCoordinator(
            catalog: catalog,
            permanentIndex: SpotlightEntityIndex()
        )
        self.coordinator = coordinator
        reconciler = SourceReconciler(
            scanner: scanner,
            fingerprintStore: fingerprintStore,
            coordinator: coordinator
        )
        let contextSnapshotStore = PersistentContextSnapshotStore()
        openingCoordinator = EntityOpeningCoordinator(
            catalog: catalog,
            openers: [
                ConfiguredDocumentOpener(
                    accessProvider: store,
                    contextSnapshotStore: contextSnapshotStore
                )
            ]
        )
        contextCoordinator = ContextCoordinator(catalog: catalog)
        self.contextSnapshotStore = contextSnapshotStore
        self.contextPublisher = contextPublisher
            ?? SpotlightLiveContextIndex(catalog: catalog)
        sourceChangeCoalescer = SourceChangeCoalescer { [weak self] sourceURLs in
            await self?.reconcileChangedSources(sourceURLs)
        }
        Task {
            sources = await store.load()
            for snapshot in await contextSnapshotStore.snapshots() {
                await contextCoordinator.ingest(snapshot)
            }
            try? await refreshCurrentContext()
            restartSourceObservation()
            isLoading = false
            await reindexAll()
        }
    }

    isolated deinit {
        sourceObservationTask?.cancel()
        sourceChangeSubscription?.cancel()
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Knowledge Directory"
        panel.message = "BrainSurfacer will read Markdown and Org files in this directory."
        panel.prompt = "Add Source"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = true

        guard panel.runModal() == .OK else {
            return
        }
        add(panel.urls)
    }

    @discardableResult
    func acceptDrop(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else {
            return false
        }
        add(urls)
        return true
    }

    func remove(_ source: SourceDirectory) {
        Task {
            sources = await store.remove(source)
            restartSourceObservation()
            do {
                try await reconciler.remove(source)
                indexStatusBySource.removeValue(forKey: source.id)
            } catch {
                errorMessage = "The source was removed, but its Spotlight entries couldn’t be deleted: \(error.localizedDescription)"
                return
            }
            do {
                try await refreshCurrentContext()
            } catch {
                errorMessage = "The source was removed, but BrainSurfacer couldn’t "
                    + "refresh live context: \(error.localizedDescription)"
            }
        }
    }

    func updateSourceConfiguration(
        pathPolicy: SourcePathPolicy,
        indexingMode: SourceIndexingMode,
        discoveryScope: SourceDiscoveryScope,
        for source: SourceDirectory
    ) {
        guard pathPolicy != source.pathPolicy
                || indexingMode != source.indexingMode
                || discoveryScope != source.discoveryScope else {
            return
        }
        Task {
            sources = await store.updateConfiguration(
                pathPolicy: pathPolicy,
                indexingMode: indexingMode,
                discoveryScope: discoveryScope,
                for: source
            )
            restartSourceObservation()
            guard let updatedSource = sources.first(where: { $0.id == source.id }) else {
                return
            }
            await reindex(updatedSource)
        }
    }

    func reindexAll() async {
        let isFullRebuild: Bool
        do {
            isFullRebuild = try await coordinator.prepareForReindex()
            if !isFullRebuild {
                try await coordinator.replayPendingChanges()
            }
        } catch {
            errorMessage = "BrainSurfacer couldn’t prepare its index: "
                + error.localizedDescription
            return
        }

        var allSourcesSucceeded = true
        for source in sources {
            if await !reindex(source) {
                allSourcesSucceeded = false
            }
        }

        guard isFullRebuild else {
            return
        }
        guard allSourcesSucceeded else {
            errorMessage = "BrainSurfacer couldn’t finish rebuilding its index. "
                + "The rebuild will be retried."
            return
        }
        do {
            try await coordinator.completeFullRebuild()
        } catch {
            errorMessage = "BrainSurfacer rebuilt its index but couldn’t record "
                + "completion: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func reindex(_ source: SourceDirectory) async -> Bool {
        indexStatusBySource[source.id, default: SourceIndexStatus()].state = .indexing

        do {
            let result = try await reconciler.reconcile(source)
            indexStatusBySource[source.id] = SourceIndexStatus(
                state: source.indexingMode == .paused ? .paused : .indexed,
                fileCount: result.fileCount,
                entityCount: result.entities.count,
                diagnosticCount: result.diagnostics.count,
                indexedAt: Date()
            )
            do {
                try await refreshCurrentContext()
            } catch {
                errorMessage = "BrainSurfacer indexed \(source.url.lastPathComponent) "
                    + "but couldn’t refresh live context: \(error.localizedDescription)"
            }
            return true
        } catch {
            var status = indexStatusBySource[source.id, default: SourceIndexStatus()]
            status.state = .failed(error.localizedDescription)
            indexStatusBySource[source.id] = status
            return false
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func ingestEditorContext(_ update: EditorContextUpdate) async {
        do {
            let enrolledURLs = await store.enrolledDocumentURLs(
                in: update.documents.map { $0.anchor.fileURL }
            )
            let acceptedDocuments = update.documents.filter {
                enrolledURLs.contains($0.anchor.fileURL.standardizedFileURL)
            }
            let acceptedUpdate = try EditorContextUpdate(
                providerID: update.providerID,
                observedAt: update.observedAt,
                timeToLive: update.timeToLive,
                documents: acceptedDocuments
            )
            let snapshot = try acceptedUpdate.contextSnapshot()
            try await contextSnapshotStore.replace(snapshot)
            await contextCoordinator.ingest(snapshot)

            let rejectedCount = update.documents.count - acceptedDocuments.count
            contextStatusMessage = rejectedCount == 0
                ? nil
                : "Ignored \(rejectedCount) document"
                    + (rejectedCount == 1 ? "" : "s")
                    + " outside enrolled sources."
            try await refreshCurrentContext()
        } catch {
            errorMessage = "BrainSurfacer rejected an editor-context update: "
                + error.localizedDescription
        }
    }

    func refreshCurrentContext() async throws {
        currentContext = try await contextCoordinator.currentContext()
        do {
            try await contextPublisher.publish(currentContext)
        } catch {
            errorMessage = "BrainSurfacer refreshed live context but couldn’t publish "
                + "its expiring Spotlight summary: \(error.localizedDescription)"
        }
    }

    func removeContextProvider(_ providerID: String) async {
        await contextCoordinator.removeProvider(identifiedBy: providerID)
        contextStatusMessage = nil
        do {
            try await contextSnapshotStore.removeProvider(identifiedBy: providerID)
            try await refreshCurrentContext()
        } catch {
            errorMessage = "BrainSurfacer couldn’t refresh live context: "
                + error.localizedDescription
        }
    }

    var contextProviderIDs: [String] {
        let resolvedProviders = currentContext.resolved.flatMap {
            $0.signals.map(\.providerID)
        }
        let unresolvedProviders = currentContext.unresolved.map(\.providerID)
        return Set(resolvedProviders + unresolvedProviders).sorted()
    }

    func search(_ text: String) async {
        searchGeneration += 1
        let generation = searchGeneration
        let searchText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !searchText.isEmpty else {
            searchResults = []
            searchErrorMessage = nil
            isSearching = false
            return
        }

        isSearching = true
        searchErrorMessage = nil

        do {
            let results = try await entitySearch.search(searchText, limit: 20)
            let liveContext = (try? await contextCoordinator.currentContext())
                ?? CurrentContext(resolved: [], unresolved: [])
            guard generation == searchGeneration else {
                return
            }
            currentContext = liveContext
            searchResults = ContextualSearchReranker().rerank(
                results,
                using: liveContext
            )
            isSearching = false
        } catch is CancellationError {
            guard generation == searchGeneration else {
                return
            }
            isSearching = false
        } catch {
            guard generation == searchGeneration else {
                return
            }
            searchResults = []
            searchErrorMessage = error.localizedDescription
            isSearching = false
        }
    }

    func clearSearch() {
        searchGeneration += 1
        searchResults = []
        searchErrorMessage = nil
        isSearching = false
    }

    func presentSearch(_ term: String) {
        searchPresentationRequest = SearchPresentationRequest(term: term)
    }

    func consumeSearchPresentationRequest() -> String? {
        defer { searchPresentationRequest = nil }
        return searchPresentationRequest?.term
    }

    func open(_ result: EntitySearchResult) {
        if let entityID = result.entityID {
            open(.entityID(entityID))
        } else if let sourceURL = result.sourceURL {
            open(.file(sourceURL))
        }
    }

    func open(_ reference: EntityReference) {
        Task {
            do {
                try await openingCoordinator.open(reference)
            } catch EntityOpeningError.failureAlreadyPresented(_) {
                // NSWorkspace has already shown the actionable system dialog.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    var totalFileCount: Int {
        indexStatusBySource.values.reduce(0) { $0 + $1.fileCount }
    }

    var totalEntityCount: Int {
        indexStatusBySource.values.reduce(0) { $0 + $1.entityCount }
    }

    var totalDiagnosticCount: Int {
        indexStatusBySource.values.reduce(0) { $0 + $1.diagnosticCount }
    }

    var isIndexing: Bool {
        indexStatusBySource.values.contains { $0.state == .indexing }
    }

    private func add(_ urls: [URL]) {
        Task {
            do {
                let previousIDs = Set(sources.map(\.id))
                sources = try await store.add(urls)
                restartSourceObservation()
                for source in sources where !previousIDs.contains(source.id) {
                    await reindex(source)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func restartSourceObservation() {
        let observedSources = sources.filter { $0.indexingMode != .paused }
        guard !observedSources.isEmpty else {
            sourceObservationTask?.cancel()
            sourceObservationTask = nil
            sourceChangeSubscription?.cancel()
            sourceChangeSubscription = nil
            return
        }

        do {
            let subscription = try sourceObserver.observe(observedSources)
            let observationTask = Task { [weak self] in
                for await sourceURLs in subscription.events {
                    guard !Task.isCancelled, let self else {
                        return
                    }
                    await self.sourceChangeCoalescer?.submit(sourceURLs)
                }
            }
            let previousTask = sourceObservationTask
            let previousSubscription = sourceChangeSubscription
            sourceObservationTask = observationTask
            sourceChangeSubscription = subscription
            previousTask?.cancel()
            previousSubscription?.cancel()
        } catch {
            sourceObservationTask?.cancel()
            sourceObservationTask = nil
            sourceChangeSubscription?.cancel()
            sourceChangeSubscription = nil
            errorMessage = "BrainSurfacer couldn’t watch its source directories: "
                + error.localizedDescription
        }
    }

    private func reconcileChangedSources(_ sourceURLs: Set<URL>) async {
        let standardizedURLs = Set(sourceURLs.map(\.standardizedFileURL))
        let changedSources = sources.filter {
            standardizedURLs.contains($0.url.standardizedFileURL)
        }
        for source in changedSources {
            await reindex(source)
        }
    }
}

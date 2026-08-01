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
        case failed(String)
    }

    var state: State = .waiting
    var fileCount = 0
    var entityCount = 0
    var diagnosticCount = 0
    var indexedAt: Date?
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
    var errorMessage: String?

    private let store: SourceDirectoryStore
    private let scanner: SourceDirectoryScanner
    private let coordinator: IndexingCoordinator
    private let entitySearch: any EntitySearch
    private var searchGeneration = 0

    init(
        store: SourceDirectoryStore = SourceDirectoryStore(),
        scanner: SourceDirectoryScanner = SourceDirectoryScanner(),
        entitySearch: any EntitySearch = SpotlightEntitySearch()
    ) {
        self.store = store
        self.scanner = scanner
        self.entitySearch = entitySearch
        let catalog = PersistentEntityCatalog(
            storageURL: PersistentEntityCatalog.defaultStorageURL()
        )
        coordinator = IndexingCoordinator(
            catalog: catalog,
            permanentIndex: SpotlightEntityIndex()
        )
        Task {
            sources = await store.load()
            isLoading = false
            await reindexAll()
        }
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
            do {
                try await coordinator.replaceEntities(from: source.url, with: [])
                indexStatusBySource.removeValue(forKey: source.id)
            } catch {
                errorMessage = "The source was removed, but its Spotlight entries couldn’t be deleted: \(error.localizedDescription)"
            }
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
            let scanner = self.scanner
            let result = try await Task.detached(priority: .utility) {
                try scanner.scan(source)
            }.value
            try await coordinator.replaceEntities(
                from: source.url,
                with: result.entities
            )
            indexStatusBySource[source.id] = SourceIndexStatus(
                state: .indexed,
                fileCount: result.fileCount,
                entityCount: result.entities.count,
                diagnosticCount: result.diagnostics.count,
                indexedAt: Date()
            )
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
            guard generation == searchGeneration else {
                return
            }
            searchResults = results
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
                for source in sources where !previousIDs.contains(source.id) {
                    await reindex(source)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

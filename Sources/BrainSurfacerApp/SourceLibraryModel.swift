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
    var errorMessage: String?

    private let store: SourceDirectoryStore
    private let scanner: SourceDirectoryScanner
    private let coordinator: IndexingCoordinator

    init(
        store: SourceDirectoryStore = SourceDirectoryStore(),
        scanner: SourceDirectoryScanner = SourceDirectoryScanner()
    ) {
        self.store = store
        self.scanner = scanner
        let catalog = InMemoryEntityCatalog()
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
        for source in sources {
            await reindex(source)
        }
    }

    func reindex(_ source: SourceDirectory) async {
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
        } catch {
            var status = indexStatusBySource[source.id, default: SourceIndexStatus()]
            status.state = .failed(error.localizedDescription)
            indexStatusBySource[source.id] = status
        }
    }

    func clearError() {
        errorMessage = nil
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

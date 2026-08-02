import AppKit
import BrainSurfacerApple
import BrainSurfacerCore
import BrainSurfacerFilesystem
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case sources = "Sources"
        case index = "Index"
        case context = "Live Context"
        case openers = "Openers"

        var id: Self { self }

        var icon: String {
            switch self {
            case .sources: "folder"
            case .index: "sparkle.magnifyingglass"
            case .context: "rectangle.on.rectangle"
            case .openers: "arrow.up.forward.app"
            }
        }
    }

    @State private var selection: Section? = .sources
    @State private var sourceLibrary = SourceLibraryModel()

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.icon)
            }
            .navigationTitle("BrainSurfacer")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            detail
        }
        .onOpenURL(perform: handleIncomingURL)
        .onReceive(
            NotificationCenter.default.publisher(
                for: BrainSurfacerNavigationRequests.didSubmitSearch
            )
        ) { _ in
            consumePendingSearch()
        }
        .task {
            consumePendingSearch()
        }
        .alert(
            "BrainSurfacer",
            isPresented: Binding(
                get: { sourceLibrary.errorMessage != nil },
                set: { if !$0 { sourceLibrary.clearError() } }
            )
        ) {
            Button("OK", action: sourceLibrary.clearError)
        } message: {
            Text(sourceLibrary.errorMessage ?? "The operation could not be completed.")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .sources:
            SourcesView(model: sourceLibrary)
        case .index:
            IndexView(model: sourceLibrary)
        case .context:
            EmptyState(
                icon: "rectangle.on.rectangle.slash",
                title: "No live context providers",
                message: "Editor connectors will report visible and nearby work separately from the permanent index."
            )
        case .openers:
            OpenersView()
        case nil:
            ContentUnavailableView("Select a section", systemImage: "brain")
        }
    }

    private func handleIncomingURL(_ url: URL) {
        guard let link = BrainSurfacerDeepLink(url: url) else {
            return
        }
        switch link {
        case let .entity(entityID):
            sourceLibrary.open(.entityID(entityID))
        case let .search(term):
            selection = .index
            sourceLibrary.presentSearch(term)
        }
    }

    private func consumePendingSearch() {
        guard let term = BrainSurfacerNavigationRequests.consumePendingSearch() else {
            return
        }
        selection = .index
        sourceLibrary.presentSearch(term)
    }
}

private struct SourcesView: View {
    let model: SourceLibraryModel
    @State private var isDropTarget = false

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView("Loading sources…")
            } else if model.sources.isEmpty {
                ContentUnavailableView {
                    Label("Choose what to surface", systemImage: "folder.badge.plus")
                } description: {
                    Text("Only explicitly approved Markdown and Org directories will be indexed. You can also drag a folder here.")
                        .frame(maxWidth: 460)
                } actions: {
                    Button("Add Source…", action: model.chooseDirectory)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List(model.sources) { source in
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.secondary)
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.url.lastPathComponent)
                                .font(.headline)
                            Text(source.url.path(percentEncoded: false))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        SourceStatusLabel(
                            status: model.indexStatusBySource[source.id]
                        )
                        Button {
                            model.remove(source)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove source")
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        Button("Remove Source", role: .destructive) {
                            model.remove(source)
                        }
                    }
                }
            }
        }
        .navigationTitle("Sources")
        .toolbar {
            ToolbarItem {
                Button("Add Source…", systemImage: "plus", action: model.chooseDirectory)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.acceptDrop(urls)
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct IndexView: View {
    let model: SourceLibraryModel
    @State private var searchText = ""

    var body: some View {
        Group {
            if model.sources.isEmpty {
                ContentUnavailableView {
                    Label("No sources", systemImage: "folder.badge.plus")
                } description: {
                    Text("Add a Markdown or Org directory in Sources to begin indexing.")
                }
            } else {
                List {
                    Section("Summary") {
                        LabeledContent("Files", value: model.totalFileCount.formatted())
                        LabeledContent("Entities", value: model.totalEntityCount.formatted())
                        if model.totalDiagnosticCount > 0 {
                            LabeledContent(
                                "Diagnostics",
                                value: model.totalDiagnosticCount.formatted()
                            )
                        }
                    }

                    Section("Sources") {
                        ForEach(model.sources) { source in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Label(
                                        source.url.lastPathComponent,
                                        systemImage: "folder"
                                    )
                                    Spacer()
                                    SourceStatusLabel(
                                        status: model.indexStatusBySource[source.id]
                                    )
                                }
                                if let status = model.indexStatusBySource[source.id] {
                                    statusDetails(status)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    Section("Search") {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("Search indexed knowledge", text: $searchText)
                                .textFieldStyle(.plain)
                            if model.isSearching {
                                ProgressView()
                                    .controlSize(.small)
                            } else if !searchText.isEmpty {
                                Button {
                                    searchText = ""
                                    model.clearSearch()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Clear search")
                            }
                        }

                        if let message = model.searchErrorMessage {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        } else if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                  !model.isSearching,
                                  model.searchResults.isEmpty {
                            ContentUnavailableView.search(text: searchText)
                        } else {
                            ForEach(model.searchResults) { result in
                                Button {
                                    model.open(result)
                                } label: {
                                    SearchResultRow(result: result)
                                }
                                .buttonStyle(.plain)
                                .help("Open in the configured application")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Index")
        .toolbar {
            ToolbarItem {
                Button {
                    Task {
                        await model.reindexAll()
                    }
                } label: {
                    Label("Reindex All", systemImage: "arrow.clockwise")
                }
                .disabled(model.sources.isEmpty || model.isIndexing)
            }
        }
        .task(id: searchText) {
            guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                model.clearSearch()
                return
            }

            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            await model.search(searchText)
        }
        .onAppear(perform: applySearchPresentationRequest)
        .onChange(of: model.searchPresentationRequest) {
            applySearchPresentationRequest()
        }
        .onDisappear {
            model.clearSearch()
        }
    }

    @ViewBuilder
    private func statusDetails(_ status: SourceIndexStatus) -> some View {
        switch status.state {
        case .waiting:
            Text("Waiting to index")
                .foregroundStyle(.secondary)
        case .indexing:
            Text("Scanning Markdown and Org files…")
                .foregroundStyle(.secondary)
        case .indexed:
            Text(
                "\(status.fileCount) files · \(status.entityCount) entities"
                    + (status.diagnosticCount == 0 ? "" : " · \(status.diagnosticCount) diagnostics")
            )
            .foregroundStyle(.secondary)
        case let .failed(message):
            Text(message)
                .foregroundStyle(.red)
        }
    }

    private func applySearchPresentationRequest() {
        guard let term = model.consumeSearchPresentationRequest() else {
            return
        }
        searchText = term
    }
}

private struct SearchResultRow: View {
    let result: EntitySearchResult

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(result.title)
                    .font(.headline)

                if let sourceURL = result.sourceURL {
                    Text(sourceURL.path(percentEncoded: false))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let summary = result.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct SourceStatusLabel: View {
    let status: SourceIndexStatus?

    var body: some View {
        switch status?.state {
        case .indexing:
            ProgressView()
                .controlSize(.small)
                .help("Indexing")
        case .indexed:
            Label("Indexed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.iconOnly)
                .help("Indexed")
        case .failed:
            Label("Indexing failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .labelStyle(.iconOnly)
                .help("Indexing failed")
        case .waiting, nil:
            Label("Waiting", systemImage: "clock")
                .foregroundStyle(.secondary)
                .labelStyle(.iconOnly)
                .help("Waiting to index")
        }
    }
}

private struct OpenersView: View {
    @AppStorage(DocumentOpeningSettings.preferenceKey)
    private var preference = DocumentOpeningPreference.systemDefault.rawValue
    @AppStorage(DocumentOpeningSettings.emacsApplicationPathKey)
    private var emacsApplicationPath = ""

    var body: some View {
        Form {
            Section("Document opener") {
                Picker("Open indexed items with", selection: $preference) {
                    ForEach(DocumentOpeningPreference.allCases) { opener in
                        Text(opener.title).tag(opener.rawValue)
                    }
                }

                Text(openerExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if preference == DocumentOpeningPreference.emacs.rawValue {
                Section("Emacs application") {
                    LabeledContent("Application") {
                        Text(
                            emacsApplicationPath.isEmpty
                                ? "Auto-detect Emacs.app"
                                : URL(fileURLWithPath: emacsApplicationPath).lastPathComponent
                        )
                        .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button("Choose Emacs.app…", action: chooseEmacsApplication)
                        if !emacsApplicationPath.isEmpty {
                            Button("Use Auto-detected App") {
                                emacsApplicationPath = ""
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Openers")
    }

    private var openerExplanation: String {
        switch DocumentOpeningPreference(rawValue: preference) ?? .systemDefault {
        case .systemDefault:
            "Uses the application associated with each source file."
        case .obsidian:
            "Uses Obsidian’s URI and includes the Markdown heading when one is available. Falls back to the default application if Obsidian cannot open it."
        case .emacs:
            "Launches Emacs with the source line and column. Falls back to the default application if Emacs cannot open it."
        }
    }

    private func chooseEmacsApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose Emacs"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        emacsApplicationPath = url.path
    }
}

private struct EmptyState: View {
    var icon: String
    var title: String
    var message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(message)
                .frame(maxWidth: 460)
        }
        .navigationTitle(title)
    }
}

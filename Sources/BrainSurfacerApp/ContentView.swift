import AppKit
import AppIntents
import BrainSurfacerApple
import BrainSurfacerCore
import BrainSurfacerFilesystem
import BrainSurfacerModel
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
            LiveContextView(model: sourceLibrary)
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
        case let .context(update):
            selection = .context
            Task {
                await sourceLibrary.ingestEditorContext(update)
            }
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

private struct LiveContextView: View {
    let model: SourceLibraryModel

    var body: some View {
        Group {
            if model.contextProviderIDs.isEmpty {
                ContentUnavailableView {
                    Label(
                        "No live editor context",
                        systemImage: "rectangle.on.rectangle.slash"
                    )
                } description: {
                    Text(
                        "Editor connectors can report selected, visible, and "
                            + "open Markdown or Org documents. Context expires "
                            + "automatically and never changes permanent indexing."
                    )
                    .frame(maxWidth: 520)
                }
            } else {
                List {
                    if let message = model.contextStatusMessage {
                        Section {
                            Label(message, systemImage: "exclamationmark.shield")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Providers") {
                        ForEach(model.contextProviderIDs, id: \.self) { providerID in
                            HStack {
                                Label(providerID, systemImage: "puzzlepiece.extension")
                                Spacer()
                                Button("Disconnect", systemImage: "xmark.circle") {
                                    Task {
                                        await model.removeContextProvider(providerID)
                                    }
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help("Remove this provider’s live context")
                            }
                        }
                    }

                    if !model.currentContext.resolved.isEmpty {
                        Section("Resolved context") {
                            ForEach(
                                model.currentContext.resolved,
                                id: \.entity.id
                            ) { item in
                                Button {
                                    model.open(.entityID(item.entity.id))
                                } label: {
                                    LiveContextRow(item: item)
                                }
                                .buttonStyle(.plain)
                                .appEntityIdentifier(
                                    BrainSurfacerAppEntityAnnotations.identifier(
                                        for: item.entity
                                    )
                                )
                                .help("Open in the configured application")
                            }
                        }
                    }

                    if !model.currentContext.unresolved.isEmpty {
                        Section("Waiting for the catalog") {
                            ForEach(
                                Array(model.currentContext.unresolved.enumerated()),
                                id: \.offset
                            ) { _, item in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(contextReferenceDescription(
                                        item.contribution.reference
                                    ))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    Text(item.providerID + " · "
                                        + item.contribution.relevance.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Live Context")
        .task(id: model.currentContext.nextExpiration) {
            guard let expiration = model.currentContext.nextExpiration else {
                return
            }
            let delay = max(0, expiration.timeIntervalSinceNow)
            do {
                try await Task.sleep(for: .seconds(delay))
                try await model.refreshCurrentContext()
            } catch is CancellationError {
                return
            } catch {
                model.errorMessage = "BrainSurfacer couldn’t refresh live context: "
                    + error.localizedDescription
            }
        }
    }

    private func contextReferenceDescription(_ reference: EntityReference) -> String {
        switch reference {
        case let .entityID(identifier):
            identifier.rawValue
        case let .file(url):
            url.path(percentEncoded: false)
        case let .sourceAnchor(anchor):
            anchor.fileURL.path(percentEncoded: false)
        case let .providerLocal(providerID, value):
            providerID + ":" + value
        }
    }
}

private struct LiveContextRow: View {
    let item: ResolvedContextItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.entity.kind == .note ? "doc.text" : "text.alignleft")
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.entity.title)
                    .font(.headline)
                Text(item.entity.source.fileURL.path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    ForEach(
                        ContextRelevance.allCases.filter(
                            Set(item.signals.map(\.relevance)).contains
                        ),
                        id: \.self
                    ) {
                        Text($0.displayName)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
            Spacer()
            Text("\(item.score)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Current context score")
        }
        .padding(.vertical, 3)
    }
}

private extension ContextRelevance {
    var displayName: String {
        switch self {
        case .selected: "Selected"
        case .visible: "Visible"
        case .currentTask: "Current task"
        case .activeProject: "Active project"
        case .open: "Open"
        case .neighboring: "Nearby"
        case .recent: "Recent"
        }
    }
}

private struct SourcesView: View {
    let model: SourceLibraryModel
    @State private var isDropTarget = false
    @State private var editingSource: SourceDirectory?

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
                            Text(source.indexingConfigurationSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        SourceStatusLabel(
                            status: model.indexStatusBySource[source.id]
                        )
                        Button {
                            editingSource = source
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Edit indexing settings")
                        .help("Edit indexing settings")
                        Button {
                            model.remove(source)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove source")
                        .help("Remove source")
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        Button("Edit Indexing Settings…") {
                            editingSource = source
                        }
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
        .sheet(item: $editingSource) { source in
            SourceIndexingSettingsEditor(source: source) { policy, mode, scope in
                model.updateSourceConfiguration(
                    pathPolicy: policy,
                    indexingMode: mode,
                    discoveryScope: scope,
                    for: source
                )
            }
        }
    }
}

private struct SourceIndexingSettingsEditor: View {
    @Environment(\.dismiss) private var dismiss
    let source: SourceDirectory
    let onSave: (
        SourcePathPolicy,
        SourceIndexingMode,
        SourceDiscoveryScope
    ) -> Void
    @State private var indexingMode: SourceIndexingMode
    @State private var discoveryScope: SourceDiscoveryScope
    @State private var includePatterns: String
    @State private var excludePatterns: String

    init(
        source: SourceDirectory,
        onSave: @escaping (
            SourcePathPolicy,
            SourceIndexingMode,
            SourceDiscoveryScope
        ) -> Void
    ) {
        self.source = source
        self.onSave = onSave
        _indexingMode = State(initialValue: source.indexingMode)
        _discoveryScope = State(initialValue: source.discoveryScope)
        _includePatterns = State(
            initialValue: source.pathPolicy.includePatterns.joined(separator: "\n")
        )
        _excludePatterns = State(
            initialValue: source.pathPolicy.excludePatterns.joined(separator: "\n")
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Source") {
                    LabeledContent("Folder", value: source.url.lastPathComponent)
                    Text(source.url.path(percentEncoded: false))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Section("Indexing mode") {
                    Picker("Mode", selection: $indexingMode) {
                        ForEach(SourceIndexingMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Text(indexingMode.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Discovery") {
                    Picker("Available in", selection: $discoveryScope) {
                        ForEach(SourceDiscoveryScope.allCases, id: \.self) { scope in
                            Text(scope.displayName).tag(scope)
                        }
                    }
                    Text(discoveryScope.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Include patterns") {
                    TextEditor(text: $includePatterns)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 90)
                    Text(
                        "One root-relative glob per line. Leave empty to include every supported Markdown and Org file."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("Exclude patterns") {
                    TextEditor(text: $excludePatterns)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 90)
                    Text(
                        "Exclusions override inclusions. Use * within one path "
                            + "component, ? for one character, and ** across folders."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Indexing Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(
                            SourcePathPolicy(
                                includePatterns: patternLines(includePatterns),
                                excludePatterns: patternLines(excludePatterns)
                            ),
                            indexingMode,
                            discoveryScope
                        )
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    private func patternLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
    }
}

private extension SourceDirectory {
    var indexingConfigurationSummary: String {
        indexingMode.displayName + " · " + discoveryScope.displayName
            + " · " + pathPolicy.displaySummary
    }
}

private extension SourceDiscoveryScope {
    var displayName: String {
        switch self {
        case .localAndApple:
            "Spotlight & Siri"
        case .localOnly:
            "BrainSurfacer only"
        }
    }

    var explanation: String {
        switch self {
        case .localAndApple:
            "Keep this source searchable in BrainSurfacer and donate its derived entities to Spotlight and Siri."
        case .localOnly:
            "Keep this source searchable only inside BrainSurfacer. Remove and withhold its Spotlight and Siri projections."
        }
    }
}

private extension SourceIndexingMode {
    var displayName: String {
        switch self {
        case .fullContent:
            "Full content"
        case .metadataOnly:
            "Titles and metadata"
        case .paused:
            "Paused"
        }
    }

    var explanation: String {
        switch self {
        case .fullContent:
            "Index titles, structure, metadata, summaries, and searchable body text."
        case .metadataOnly:
            "Index titles, structure, tags, dates, and source anchors without body text, summaries, or links."
        case .paused:
            "Keep this source enrolled but remove its derived catalog, fingerprints, and Spotlight entries."
        }
    }
}

private extension SourcePathPolicy {
    var displaySummary: String {
        guard !isUnrestricted else {
            return "All supported files"
        }
        let included = includePatterns.isEmpty
            ? "all supported files"
            : "\(includePatterns.count) include rule"
                + (includePatterns.count == 1 ? "" : "s")
        guard !excludePatterns.isEmpty else {
            return included
        }
        return included + " · \(excludePatterns.count) exclusion"
            + (excludePatterns.count == 1 ? "" : "s")
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
        case .paused:
            Text("Indexing paused · derived data removed")
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
        case .paused:
            Label("Paused", systemImage: "pause.circle.fill")
                .foregroundStyle(.secondary)
                .labelStyle(.iconOnly)
                .help("Indexing paused")
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
            "Reuses Emacs or Obsidian when exactly one reports the file open. "
                + "Otherwise, it uses the application associated with the source file."
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

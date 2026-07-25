import BrainSurfacerFilesystem
import SwiftUI

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
            EmptyState(
                icon: "arrow.up.forward.app",
                title: "Use the source’s default app",
                message: "Configurable Emacs, Obsidian, VS Code, and BBEdit openers will preserve headings and positions where possible."
            )
        case nil:
            ContentUnavailableView("Select a section", systemImage: "brain")
        }
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
        .alert(
            "Couldn’t Add Source",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.clearError() } }
            )
        ) {
            Button("OK", action: model.clearError)
        } message: {
            Text(model.errorMessage ?? "The directory could not be added.")
        }
    }
}

private struct IndexView: View {
    let model: SourceLibraryModel

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

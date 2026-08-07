import AppKit
import BrainSurfacerCore
import BrainSurfacerFilesystem
import BrainSurfacerModel
import Foundation

public enum DocumentOpeningPreference: String, CaseIterable, Hashable,
    Identifiable, Sendable {
    case systemDefault
    case obsidian
    case emacs

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .systemDefault: "Automatic"
        case .obsidian: "Obsidian"
        case .emacs: "Emacs"
        }
    }
}

public enum DocumentOpeningSettings {
    public static let preferenceKey = "documentOpeningPreference"
    public static let emacsApplicationPathKey = "emacsApplicationPath"
}

struct LiveContextOpeningPreferenceResolver: Sendable {
    // Connector identity contract: keep these namespaces aligned with
    // Connectors/Emacs/brainsurfacer.el and Connectors/Obsidian/src/main.ts.
    // Customized Emacs IDs retain recognition when they use a dot suffix.
    private static let emacsProviderID = "org.gnu.Emacs"
    private static let obsidianProviderID = "md.obsidian.BrainSurfacer"

    private let snapshotStore: PersistentContextSnapshotStore

    init(
        snapshotStore: PersistentContextSnapshotStore =
            PersistentContextSnapshotStore()
    ) {
        self.snapshotStore = snapshotStore
    }

    func preference(
        for fileURL: URL,
        at date: Date = Date()
    ) async -> DocumentOpeningPreference? {
        Self.preference(
            for: fileURL,
            in: await snapshotStore.snapshots(at: date),
            at: date
        )
    }

    static func preference(
        for fileURL: URL,
        in snapshots: [ContextSnapshot],
        at date: Date
    ) -> DocumentOpeningPreference? {
        let targetPath = fileURL.standardizedFileURL.path(percentEncoded: false)
        var preferences: Set<DocumentOpeningPreference> = []

        for snapshot in snapshots {
            guard let preference = preference(forProviderID: snapshot.providerID),
                  snapshot.contributions.contains(where: {
                      contribution($0, reportsOpenPath: targetPath, at: date)
                  }) else {
                continue
            }
            preferences.insert(preference)
            if preferences.count > 1 {
                return nil
            }
        }
        return preferences.first
    }

    private static func preference(
        forProviderID providerID: String
    ) -> DocumentOpeningPreference? {
        if providerID == emacsProviderID
            || providerID.hasPrefix("\(emacsProviderID).") {
            return .emacs
        }
        if providerID == obsidianProviderID
            || providerID.hasPrefix("\(obsidianProviderID).") {
            return .obsidian
        }
        return nil
    }

    private static func contribution(
        _ contribution: ContextContribution,
        reportsOpenPath targetPath: String,
        at date: Date
    ) -> Bool {
        guard contribution.expiresAt > date,
              [.selected, .visible, .open].contains(contribution.relevance),
              let fileURL = fileURL(for: contribution.reference) else {
            return false
        }
        return fileURL.standardizedFileURL.path(percentEncoded: false) == targetPath
    }

    private static func fileURL(for reference: EntityReference) -> URL? {
        switch reference {
        case let .file(fileURL): fileURL
        case let .sourceAnchor(anchor): anchor.fileURL
        case .entityID, .providerLocal: nil
        }
    }
}

public enum DocumentOpeningFailure: LocalizedError, Sendable {
    case missingSource(URL)
    case applicationUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case let .missingSource(url):
            "The source file no longer exists at \(url.path(percentEncoded: false))."
        case let .applicationUnavailable(name):
            "\(name) is not installed or its application location is no longer valid."
        }
    }
}

/// The app-wide opener. It reads the current preference for each request so
/// App Intents and the running app always use the same routing policy.
public struct ConfiguredDocumentOpener: DocumentOpener {
    public let id = "configured-macos-opener"
    private let accessProvider: any DocumentAccessProvider
    private let contextPreferenceResolver: LiveContextOpeningPreferenceResolver

    public init(
        accessProvider: any DocumentAccessProvider = SourceDirectoryStore()
    ) {
        self.accessProvider = accessProvider
        contextPreferenceResolver = LiveContextOpeningPreferenceResolver()
    }

    public func canOpen(_ entity: KnowledgeEntity) async -> Bool {
        entity.source.fileURL.isFileURL
    }

    public func open(_ entity: KnowledgeEntity) async throws {
        let settings = await MainActor.run {
            let defaults = UserDefaults.standard
            return (
                DocumentOpeningPreference(
                    rawValue: defaults.string(
                        forKey: DocumentOpeningSettings.preferenceKey
                    ) ?? ""
                ) ?? .systemDefault,
                defaults.string(forKey: DocumentOpeningSettings.emacsApplicationPathKey)
            )
        }
        let contextualPreference: DocumentOpeningPreference?
        if settings.0 == .systemDefault {
            contextualPreference = await contextPreferenceResolver.preference(
                for: entity.source.fileURL
            )
        } else {
            contextualPreference = nil
        }
        let effectivePreference = Self.effectivePreference(
            configured: settings.0,
            contextual: contextualPreference
        )

        try await accessProvider.performWithAccess(
            to: entity.source.fileURL
        ) {
            try Self.validateSourceIfMissing(entity.source.fileURL)

            do {
                switch effectivePreference {
                case .systemDefault:
                    try await Self.openWithSystemDefault(entity.source.fileURL)
                case .obsidian:
                    guard let url = Self.obsidianURL(for: entity) else {
                        throw DocumentOpeningFailure.applicationUnavailable("Obsidian")
                    }
                    try await Self.openWithSystemDefault(
                        url,
                        promptsUserIfNeeded: false
                    )
                case .emacs:
                    try await Self.openWithEmacs(entity, configuredPath: settings.1)
                }
            } catch where effectivePreference != .systemDefault {
                // A stale configured or context-derived editor route must never
                // turn a valid Spotlight hit into a dead end.
                try await Self.openWithSystemDefault(entity.source.fileURL)
            }
        }
    }

    static func effectivePreference(
        configured: DocumentOpeningPreference,
        contextual: DocumentOpeningPreference?
    ) -> DocumentOpeningPreference {
        configured == .systemDefault ? contextual ?? .systemDefault : configured
    }

    static func obsidianURL(for entity: KnowledgeEntity) -> URL? {
        var target = entity.source.fileURL.standardizedFileURL.path
        if entity.source.fileURL.pathExtension.lowercased() == "md",
           let heading = entity.source.headingPath.last,
           !heading.isEmpty {
            target += "#\(heading)"
        }

        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: target)]
        return components.url
    }

    static func emacsArguments(for entity: KnowledgeEntity) -> [String] {
        var arguments: [String] = []
        if let line = entity.source.line {
            let column = max(entity.source.column ?? 1, 1)
            arguments.append("+\(max(line, 1)):\(column)")
        }
        arguments.append(entity.source.fileURL.standardizedFileURL.path)
        return arguments
    }

    static func isMissingSourceError(_ error: any Error) -> Bool {
        let cocoaError = error as NSError
        guard cocoaError.domain == NSCocoaErrorDomain else {
            return false
        }
        return cocoaError.code == CocoaError.Code.fileNoSuchFile.rawValue
            || cocoaError.code == CocoaError.Code.fileReadNoSuchFile.rawValue
    }

    private static func validateSourceIfMissing(_ url: URL) throws {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                throw DocumentOpeningFailure.missingSource(url)
            }
        } catch let error as DocumentOpeningFailure {
            throw error
        } catch {
            // A permission or transient filesystem error is not evidence that
            // the source disappeared. Let NSWorkspace or the editor make the
            // real open attempt and report its own actionable failure.
            guard Self.isMissingSourceError(error) else {
                return
            }
            throw DocumentOpeningFailure.missingSource(url)
        }
    }

    @MainActor
    private static func openWithSystemDefault(
        _ url: URL,
        promptsUserIfNeeded: Bool = true
    ) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.promptsUserIfNeeded = promptsUserIfNeeded
        do {
            _ = try await NSWorkspace.shared.open(
                url,
                configuration: configuration
            )
        } catch {
            if promptsUserIfNeeded {
                throw WorkspaceRejectedOpening(url: url)
            }
            throw WorkspaceProbeFailure(url: url)
        }
    }

    @MainActor
    private static func openWithEmacs(
        _ entity: KnowledgeEntity,
        configuredPath: String?
    ) async throws {
        let configuredURL = configuredPath.flatMap { path -> URL? in
            guard !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        }
        let applicationURL = configuredURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.gnu.Emacs")
        guard let applicationURL,
              FileManager.default.fileExists(atPath: applicationURL.path) else {
            throw DocumentOpeningFailure.applicationUnavailable("Emacs")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = emacsArguments(for: entity)
        _ = try await NSWorkspace.shared.open(
            [entity.source.fileURL],
            withApplicationAt: applicationURL,
            configuration: configuration
        )
    }
}

private struct WorkspaceRejectedOpening: LocalizedError,
    UserPresentedDocumentOpeningError {
    let url: URL

    var errorDescription: String? {
        "macOS could not open \(url.lastPathComponent)."
    }
}

private struct WorkspaceProbeFailure: LocalizedError, Sendable {
    let url: URL

    var errorDescription: String? {
        "No application accepted \(url.scheme ?? "the requested") URL."
    }
}

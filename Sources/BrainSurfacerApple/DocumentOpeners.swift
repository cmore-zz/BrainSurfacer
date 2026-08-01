import AppKit
import BrainSurfacerCore
import BrainSurfacerModel
import Foundation

public enum DocumentOpeningPreference: String, CaseIterable, Identifiable, Sendable {
    case systemDefault
    case obsidian
    case emacs

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .systemDefault: "Default application"
        case .obsidian: "Obsidian"
        case .emacs: "Emacs"
        }
    }
}

public enum DocumentOpeningSettings {
    public static let preferenceKey = "documentOpeningPreference"
    public static let emacsApplicationPathKey = "emacsApplicationPath"
}

public enum DocumentOpeningFailure: LocalizedError, Sendable {
    case missingSource(URL)
    case applicationUnavailable(String)
    case openRejected(URL)

    public var errorDescription: String? {
        switch self {
        case let .missingSource(url):
            "The source file no longer exists at \(url.path(percentEncoded: false))."
        case let .applicationUnavailable(name):
            "\(name) is not installed or its application location is no longer valid."
        case let .openRejected(url):
            "macOS could not open \(url.lastPathComponent)."
        }
    }
}

/// The app-wide opener. It reads the current preference for each request so
/// App Intents and the running app always use the same routing policy.
public struct ConfiguredDocumentOpener: DocumentOpener {
    public let id = "configured-macos-opener"

    public init() {}

    public func canOpen(_ entity: KnowledgeEntity) async -> Bool {
        FileManager.default.fileExists(atPath: entity.source.fileURL.path)
    }

    public func open(_ entity: KnowledgeEntity) async throws {
        guard await canOpen(entity) else {
            throw DocumentOpeningFailure.missingSource(entity.source.fileURL)
        }

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

        do {
            switch settings.0 {
            case .systemDefault:
                try await Self.openWithSystemDefault(entity.source.fileURL)
            case .obsidian:
                guard let url = Self.obsidianURL(for: entity) else {
                    throw DocumentOpeningFailure.applicationUnavailable("Obsidian")
                }
                try await Self.openWithSystemDefault(url)
            case .emacs:
                try await Self.openWithEmacs(entity, configuredPath: settings.1)
            }
        } catch where settings.0 != .systemDefault {
            // A stale editor preference must never turn a valid Spotlight hit
            // into a dead end.
            try await Self.openWithSystemDefault(entity.source.fileURL)
        }
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

    @MainActor
    private static func openWithSystemDefault(_ url: URL) async throws {
        guard NSWorkspace.shared.open(url) else {
            throw DocumentOpeningFailure.openRejected(url)
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

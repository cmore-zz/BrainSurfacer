import BrainSurfacerCore
import Foundation

public struct SourceDirectory: Identifiable, Hashable, Sendable {
    public var id: String
    public var url: URL

    public init(url: URL) {
        let url = url.standardizedFileURL
        id = url.path
        self.url = url
    }
}

/// Persists enrolled source roots and leases their security-scoped access.
/// Loading also replaces stale bookmarks before returning their resolved URLs.
public actor SourceDirectoryStore: DocumentAccessProvider {
    public enum Error: LocalizedError {
        case notDirectory(URL)

        public var errorDescription: String? {
            switch self {
            case let .notDirectory(url):
                "\"\(url.lastPathComponent)\" is not a directory."
            }
        }
    }

    private let defaults: UserDefaults
    private let storageKey: String

    public init(
        suiteName: String? = nil,
        storageKey: String = SourceEnrollmentSettings.bookmarkStorageKey
    ) {
        if let suiteName {
            defaults = UserDefaults(suiteName: suiteName) ?? .standard
        } else {
            defaults = .standard
        }
        self.storageKey = storageKey
    }

    public func load() -> [SourceDirectory] {
        let bookmarks = defaults.array(forKey: storageKey) as? [Data] ?? []
        let resolution = resolve(bookmarks)
        if resolution.bookmarks != bookmarks {
            defaults.set(resolution.bookmarks, forKey: storageKey)
        }
        return resolution.sources
    }

    public func performWithAccess(
        to documentURL: URL,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        guard let root = enclosingEnrolledRoot(for: documentURL) else {
            // Files inside the app container and other unrestricted locations
            // do not need an enrollment bookmark.
            try await operation()
            return
        }

        let didStartAccess = root.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                root.stopAccessingSecurityScopedResource()
            }
        }
        try await operation()
    }

    func enclosingEnrolledRoot(for documentURL: URL) -> URL? {
        Self.enclosingRoot(
            for: documentURL,
            among: load().map(\.url)
        )
    }

    static func enclosingRoot(for documentURL: URL, among roots: [URL]) -> URL? {
        let documentComponents = documentURL.standardizedFileURL.pathComponents
        return roots
            .map(\.standardizedFileURL)
            .filter { root in
                let rootComponents = root.pathComponents
                guard rootComponents.count <= documentComponents.count else {
                    return false
                }
                return documentComponents.prefix(rootComponents.count)
                    .elementsEqual(rootComponents)
            }
            .max { first, second in
                first.pathComponents.count < second.pathComponents.count
            }
    }

    public func add(_ urls: [URL]) throws -> [SourceDirectory] {
        var bookmarks = defaults.array(forKey: storageKey) as? [Data] ?? []
        var knownPaths = Set(resolve(bookmarks).sources.map(\.id))

        for candidate in urls {
            let url = candidate.standardizedFileURL
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw Error.notDirectory(url)
            }
            guard knownPaths.insert(url.path).inserted else {
                continue
            }

            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: [.isDirectoryKey],
                relativeTo: nil
            )
            bookmarks.append(bookmark)
        }

        defaults.set(bookmarks, forKey: storageKey)
        return resolve(bookmarks).sources
    }

    public func remove(_ source: SourceDirectory) -> [SourceDirectory] {
        let bookmarks = defaults.array(forKey: storageKey) as? [Data] ?? []
        let retained = bookmarks.filter { bookmark in
            resolve(bookmark)?.url.standardizedFileURL.path != source.id
        }
        defaults.set(retained, forKey: storageKey)
        return resolve(retained).sources
    }

    private func resolve(
        _ bookmarks: [Data]
    ) -> (sources: [SourceDirectory], bookmarks: [Data]) {
        var seen: Set<String> = []
        var sources: [SourceDirectory] = []
        var validBookmarks: [Data] = []

        for bookmark in bookmarks {
            guard let resolved = resolve(bookmark) else {
                continue
            }
            let source = SourceDirectory(url: resolved.url)
            guard seen.insert(source.id).inserted else {
                continue
            }

            sources.append(source)
            if resolved.isStale,
               let refreshed = try? refreshedBookmark(for: resolved.url) {
                validBookmarks.append(refreshed)
            } else {
                validBookmarks.append(bookmark)
            }
        }

        sources.sort {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
        return (sources, validBookmarks)
    }

    private func resolve(_ bookmark: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        return (url, isStale)
    }

    private func refreshedBookmark(for url: URL) throws -> Data {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: [.isDirectoryKey],
            relativeTo: nil
        )
    }
}

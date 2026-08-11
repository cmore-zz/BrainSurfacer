import BrainSurfacerCore
import Foundation

public struct SourceDirectory: Identifiable, Hashable, Sendable {
    public var id: String
    public var url: URL
    public var pathPolicy: SourcePathPolicy
    public var indexingMode: SourceIndexingMode
    public var discoveryScope: SourceDiscoveryScope
    public var formatOverrides: [SourceFormatOverride]

    public init(
        url: URL,
        pathPolicy: SourcePathPolicy = SourcePathPolicy(),
        indexingMode: SourceIndexingMode = .fullContent,
        discoveryScope: SourceDiscoveryScope = .localAndApple,
        formatOverrides: [SourceFormatOverride] = []
    ) {
        let url = url.standardizedFileURL
        id = url.path
        self.url = url
        self.pathPolicy = pathPolicy
        self.indexingMode = indexingMode
        self.discoveryScope = discoveryScope
        self.formatOverrides = SourceFormatOverride.normalized(formatOverrides)
    }
}

/// Persists enrolled source roots, path policies, indexing modes, discovery
/// scopes, and format overrides together, and leases their security-scoped
/// access. Loading also replaces stale bookmarks without detaching settings.
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
        let enrollments = loadEnrollments()
        let resolution = resolve(enrollments)
        if resolution.enrollments != enrollments {
            persist(resolution.enrollments)
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

    /// Returns the standardized candidates covered by an enrolled source.
    /// Context transports use this as their consent boundary before accepting
    /// editor-observed document paths.
    public func enrolledDocumentURLs(in candidates: [URL]) -> Set<URL> {
        let roots = load().map { $0.url.resolvingSymlinksInPath() }
        return Set(candidates.compactMap { candidate in
            let standardizedCandidate = candidate.standardizedFileURL
            let resolvedCandidate = standardizedCandidate.resolvingSymlinksInPath()
            guard Self.enclosingRoot(for: resolvedCandidate, among: roots) != nil else {
                return nil
            }
            return standardizedCandidate
        })
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
        let resolution = resolve(loadEnrollments())
        var enrollments = resolution.enrollments
        var knownPaths = Set(resolution.sources.map(\.id))

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
            enrollments.append(
                PersistedSourceEnrollment(
                    identifier: UUID(),
                    bookmark: bookmark,
                    pathPolicy: SourcePathPolicy(),
                    indexingMode: .fullContent,
                    discoveryScope: .localAndApple,
                    formatOverrides: []
                )
            )
        }

        persist(enrollments)
        return load()
    }

    public func remove(_ source: SourceDirectory) -> [SourceDirectory] {
        let retained = loadEnrollments().filter { enrollment in
            resolve(enrollment.bookmark)?.url.standardizedFileURL.path != source.id
        }
        persist(retained)
        return load()
    }

    public func updatePathPolicy(
        _ pathPolicy: SourcePathPolicy,
        for source: SourceDirectory
    ) -> [SourceDirectory] {
        updateEnrollment(
            pathPolicy: pathPolicy,
            indexingMode: nil,
            discoveryScope: nil,
            formatOverrides: nil,
            for: source
        )
    }

    public func updateConfiguration(
        pathPolicy: SourcePathPolicy,
        indexingMode: SourceIndexingMode,
        for source: SourceDirectory
    ) -> [SourceDirectory] {
        updateEnrollment(
            pathPolicy: pathPolicy,
            indexingMode: indexingMode,
            discoveryScope: nil,
            formatOverrides: nil,
            for: source
        )
    }

    public func updateConfiguration(
        pathPolicy: SourcePathPolicy,
        indexingMode: SourceIndexingMode,
        discoveryScope: SourceDiscoveryScope,
        for source: SourceDirectory
    ) -> [SourceDirectory] {
        updateEnrollment(
            pathPolicy: pathPolicy,
            indexingMode: indexingMode,
            discoveryScope: discoveryScope,
            formatOverrides: nil,
            for: source
        )
    }

    public func updateConfiguration(
        pathPolicy: SourcePathPolicy,
        indexingMode: SourceIndexingMode,
        discoveryScope: SourceDiscoveryScope,
        formatOverrides: [SourceFormatOverride],
        for source: SourceDirectory
    ) -> [SourceDirectory] {
        updateEnrollment(
            pathPolicy: pathPolicy,
            indexingMode: indexingMode,
            discoveryScope: discoveryScope,
            formatOverrides: formatOverrides,
            for: source
        )
    }

    private func updateEnrollment(
        pathPolicy: SourcePathPolicy,
        indexingMode: SourceIndexingMode?,
        discoveryScope: SourceDiscoveryScope?,
        formatOverrides: [SourceFormatOverride]?,
        for source: SourceDirectory
    ) -> [SourceDirectory] {
        var enrollments = loadEnrollments()
        var didChange = false
        for index in enrollments.indices {
            guard resolve(enrollments[index].bookmark)?
                .url.standardizedFileURL.path == source.id else {
                continue
            }
            let updatedMode = indexingMode ?? enrollments[index].indexingMode
            let updatedScope = discoveryScope ?? enrollments[index].discoveryScope
            let updatedOverrides = formatOverrides.map(SourceFormatOverride.normalized)
                ?? enrollments[index].formatOverrides
            guard enrollments[index].pathPolicy != pathPolicy
                    || enrollments[index].indexingMode != updatedMode
                    || enrollments[index].discoveryScope != updatedScope
                    || enrollments[index].formatOverrides != updatedOverrides else {
                continue
            }
            enrollments[index].pathPolicy = pathPolicy
            enrollments[index].indexingMode = updatedMode
            enrollments[index].discoveryScope = updatedScope
            enrollments[index].formatOverrides = updatedOverrides
            didChange = true
        }
        if didChange {
            persist(enrollments)
        }
        return load()
    }

    private func resolve(
        _ enrollments: [PersistedSourceEnrollment]
    ) -> (sources: [SourceDirectory], enrollments: [PersistedSourceEnrollment]) {
        var seen: Set<String> = []
        var sources: [SourceDirectory] = []
        var validEnrollments: [PersistedSourceEnrollment] = []

        for enrollment in enrollments {
            guard let resolved = resolve(enrollment.bookmark) else {
                continue
            }
            let source = SourceDirectory(
                url: resolved.url,
                pathPolicy: enrollment.pathPolicy,
                indexingMode: enrollment.indexingMode,
                discoveryScope: enrollment.discoveryScope,
                formatOverrides: enrollment.formatOverrides
            )
            guard seen.insert(source.id).inserted else {
                continue
            }

            sources.append(source)
            if resolved.isStale,
               let refreshed = try? refreshedBookmark(for: resolved.url) {
                validEnrollments.append(
                    PersistedSourceEnrollment(
                        identifier: enrollment.identifier,
                        bookmark: refreshed,
                        pathPolicy: enrollment.pathPolicy,
                        indexingMode: enrollment.indexingMode,
                        discoveryScope: enrollment.discoveryScope,
                        formatOverrides: enrollment.formatOverrides
                    )
                )
            } else {
                validEnrollments.append(enrollment)
            }
        }

        sources.sort {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
        return (sources, validEnrollments)
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

    private func loadEnrollments() -> [PersistedSourceEnrollment] {
        if let data = defaults.data(forKey: storageKey),
           let state = try? JSONDecoder().decode(
               PersistedSourceEnrollmentState.self,
               from: data
           ) {
            // Codable ignores unknown fields, so a newer state that still has
            // this readable core remains usable on downgrade. A genuinely
            // incompatible representation fails decoding instead.
            return state.enrollments
        }

        let legacyBookmarks = defaults.array(forKey: storageKey) as? [Data] ?? []
        let migrated = legacyBookmarks.map {
            PersistedSourceEnrollment(
                identifier: UUID(),
                bookmark: $0,
                pathPolicy: SourcePathPolicy(),
                indexingMode: .fullContent,
                discoveryScope: .localAndApple,
                formatOverrides: []
            )
        }
        if !legacyBookmarks.isEmpty {
            persist(migrated)
        }
        return migrated
    }

    private func persist(_ enrollments: [PersistedSourceEnrollment]) {
        let state = PersistedSourceEnrollmentState(enrollments: enrollments)
        guard let data = try? JSONEncoder().encode(state) else {
            return
        }
        defaults.set(data, forKey: storageKey)
    }
}

private struct PersistedSourceEnrollmentState: Codable {
    static let currentSchemaVersion = 5

    var schemaVersion = Self.currentSchemaVersion
    var enrollments: [PersistedSourceEnrollment]
}

private struct PersistedSourceEnrollment: Codable, Equatable {
    var identifier: UUID
    var bookmark: Data
    var pathPolicy: SourcePathPolicy
    var indexingMode: SourceIndexingMode
    var discoveryScope: SourceDiscoveryScope
    var formatOverrides: [SourceFormatOverride]

    private enum CodingKeys: String, CodingKey {
        case identifier
        case bookmark
        case pathPolicy
        case indexingMode
        case discoveryScope
        case formatOverrides
    }

    init(
        identifier: UUID,
        bookmark: Data,
        pathPolicy: SourcePathPolicy,
        indexingMode: SourceIndexingMode,
        discoveryScope: SourceDiscoveryScope,
        formatOverrides: [SourceFormatOverride]
    ) {
        self.identifier = identifier
        self.bookmark = bookmark
        self.pathPolicy = pathPolicy
        self.indexingMode = indexingMode
        self.discoveryScope = discoveryScope
        self.formatOverrides = SourceFormatOverride.normalized(formatOverrides)
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try values.decode(UUID.self, forKey: .identifier)
        bookmark = try values.decode(Data.self, forKey: .bookmark)
        pathPolicy = try values.decodeIfPresent(
            SourcePathPolicy.self,
            forKey: .pathPolicy
        ) ?? SourcePathPolicy()
        indexingMode = try values.decodeIfPresent(
            SourceIndexingMode.self,
            forKey: .indexingMode
        ) ?? .fullContent
        discoveryScope = try values.decodeIfPresent(
            SourceDiscoveryScope.self,
            forKey: .discoveryScope
        ) ?? .localAndApple
        let persistedOverrides = try values.decodeIfPresent(
            [PersistedSourceFormatOverride].self,
            forKey: .formatOverrides
        ) ?? []
        formatOverrides = SourceFormatOverride.normalized(
            persistedOverrides.compactMap { persisted in
                guard let target = SourceFormatOverride.Target(rawValue: persisted.format) else {
                    return nil
                }
                return SourceFormatOverride(suffix: persisted.suffix, target: target)
            }
        )
    }
}

private struct PersistedSourceFormatOverride: Decodable {
    var suffix: String
    var format: String
}

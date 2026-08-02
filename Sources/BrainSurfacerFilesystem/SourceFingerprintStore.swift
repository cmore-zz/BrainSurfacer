import Foundation

public struct SourceFileFingerprint: Codable, Equatable, Sendable {
    public var modifiedAt: Date
    public var fileSize: Int64
    public var parserRevision: Int

    public init(
        modifiedAt: Date,
        fileSize: Int64,
        parserRevision: Int = OutlineParser.outputRevision
    ) {
        self.modifiedAt = modifiedAt
        self.fileSize = fileSize
        self.parserRevision = parserRevision
    }
}

/// A disposable record of the file versions represented by the entity catalog.
/// Fingerprints are committed only after the matching catalog/index replacement
/// succeeds, so a failed reconciliation is retried on the next pass.
public actor SourceFingerprintStore {
    public static let currentSchemaVersion = 1

    public let storageURL: URL

    public init(storageURL: URL = SourceFingerprintStore.defaultStorageURL()) {
        self.storageURL = storageURL.standardizedFileURL
    }

    public static func defaultStorageURL(
        fileManager: FileManager = .default
    ) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("BrainSurfacer", isDirectory: true)
            .appendingPathComponent("source-fingerprints-v1.json", isDirectory: false)
    }

    public func fingerprints(for source: URL) -> [URL: SourceFileFingerprint] {
        let source = source.standardizedFileURL
        guard let record = load().sources.first(where: {
            $0.url.standardizedFileURL == source
        }) else {
            return [:]
        }
        return Dictionary(
            record.files.map { ($0.url.standardizedFileURL, $0.fingerprint) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    public func replaceFingerprints(
        for source: URL,
        with fingerprints: [URL: SourceFileFingerprint]
    ) throws {
        let source = source.standardizedFileURL
        var state = load()
        state.sources.removeAll { $0.url.standardizedFileURL == source }
        state.sources.append(
            SourceRecord(
                url: source,
                files: fingerprints.map {
                    FileRecord(
                        url: $0.key.standardizedFileURL,
                        fingerprint: $0.value
                    )
                }.sorted { $0.url.path < $1.url.path }
            )
        )
        state.sources.sort { $0.url.path < $1.url.path }
        try persist(state)
    }

    public func removeFingerprints(for source: URL) throws {
        let source = source.standardizedFileURL
        var state = load()
        state.sources.removeAll { $0.url.standardizedFileURL == source }
        try persist(state)
    }

    private func load() -> PersistedState {
        guard let data = try? Data(contentsOf: storageURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data),
              state.schemaVersion == Self.currentSchemaVersion else {
            return PersistedState(
                schemaVersion: Self.currentSchemaVersion,
                sources: []
            )
        }
        return state
    }

    private func persist(_ state: PersistedState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: storageURL, options: [.atomic])
    }
}

private extension SourceFingerprintStore {
    struct PersistedState: Codable {
        var schemaVersion: Int
        var sources: [SourceRecord]
    }

    struct SourceRecord: Codable {
        var url: URL
        var files: [FileRecord]
    }

    struct FileRecord: Codable {
        var url: URL
        var fingerprint: SourceFileFingerprint
    }
}

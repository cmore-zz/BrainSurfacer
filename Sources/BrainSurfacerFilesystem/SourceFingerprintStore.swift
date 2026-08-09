import Foundation

public struct SourceFileFingerprint: Codable, Equatable, Sendable {
    public static let legacyParserIdentifier = "org.brainsurfacer.legacy-outline"

    public var modifiedAt: Date
    public var fileSize: Int64
    public var parserIdentifier: String
    public var parserRevision: Int
    public var filenameSuffix: String?
    public var indexingMode: SourceIndexingMode
    public var wasExcludedByDocumentMetadata: Bool

    public init(
        modifiedAt: Date,
        fileSize: Int64,
        parserIdentifier: String,
        parserRevision: Int = OutlineParser.outputRevision,
        filenameSuffix: String? = nil,
        indexingMode: SourceIndexingMode = .fullContent,
        wasExcludedByDocumentMetadata: Bool = false
    ) {
        self.modifiedAt = modifiedAt
        self.fileSize = fileSize
        self.parserIdentifier = parserIdentifier
        self.parserRevision = parserRevision
        self.filenameSuffix = filenameSuffix
        self.indexingMode = indexingMode
        self.wasExcludedByDocumentMetadata = wasExcludedByDocumentMetadata
    }

    private enum CodingKeys: String, CodingKey {
        case modifiedAt
        case fileSize
        case parserIdentifier
        case parserRevision
        case filenameSuffix
        case indexingMode
        case wasExcludedByDocumentMetadata
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        modifiedAt = try values.decode(Date.self, forKey: .modifiedAt)
        fileSize = try values.decode(Int64.self, forKey: .fileSize)
        parserIdentifier = try values.decodeIfPresent(
            String.self,
            forKey: .parserIdentifier
        ) ?? Self.legacyParserIdentifier
        parserRevision = try values.decode(Int.self, forKey: .parserRevision)
        filenameSuffix = try values.decodeIfPresent(
            String.self,
            forKey: .filenameSuffix
        )
        indexingMode = try values.decodeIfPresent(
            SourceIndexingMode.self,
            forKey: .indexingMode
        ) ?? .fullContent
        wasExcludedByDocumentMetadata = try values.decodeIfPresent(
            Bool.self,
            forKey: .wasExcludedByDocumentMetadata
        ) ?? false
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

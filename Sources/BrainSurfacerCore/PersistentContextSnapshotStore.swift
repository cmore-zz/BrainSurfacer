import Foundation

/// Persists the latest expiring context contribution from each local provider.
///
/// The store is deliberately separate from the permanent entity catalog. It
/// lets background App Intents and policy-controlled adapters recover live
/// context without extending its provider-supplied TTL. The store itself never
/// donates to Spotlight; the Apple adapter may separately publish one expiring
/// aggregate for sources already enrolled in Apple discovery.
public actor PersistentContextSnapshotStore {
    public static let currentSchemaVersion = 1

    public let storageURL: URL

    public init(
        storageURL: URL = PersistentContextSnapshotStore.defaultStorageURL()
    ) {
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
            .appendingPathComponent("live-context-v1.json", isDirectory: false)
    }

    public func replace(
        _ snapshot: ContextSnapshot,
        at date: Date = Date()
    ) throws {
        var snapshots = loadSnapshots().compactMap {
            Self.pruned($0, at: date)
        }
        snapshots.removeAll { $0.providerID == snapshot.providerID }

        if let snapshot = Self.pruned(snapshot, at: date) {
            snapshots.append(snapshot)
        }
        snapshots.sort {
            if $0.observedAt != $1.observedAt {
                return $0.observedAt > $1.observedAt
            }
            return $0.providerID < $1.providerID
        }
        if snapshots.count > ContextCoordinator.maximumProviderCount {
            snapshots.removeLast(
                snapshots.count - ContextCoordinator.maximumProviderCount
            )
        }
        try persist(snapshots)
    }

    public func removeProvider(
        identifiedBy providerID: String,
        at date: Date = Date()
    ) throws {
        let snapshots: [ContextSnapshot] = loadSnapshots().compactMap { snapshot in
            guard snapshot.providerID != providerID else { return nil }
            return Self.pruned(snapshot, at: date)
        }
        try persist(snapshots)
    }

    public func snapshots(at date: Date = Date()) -> [ContextSnapshot] {
        loadSnapshots().compactMap { Self.pruned($0, at: date) }
    }

    private func loadSnapshots() -> [ContextSnapshot] {
        guard let data = try? Data(contentsOf: storageURL),
              let state = try? JSONDecoder().decode(State.self, from: data),
              state.schemaVersion == Self.currentSchemaVersion else {
            return []
        }
        return state.snapshots
    }

    private func persist(_ snapshots: [ContextSnapshot]) throws {
        let fileManager = FileManager.default
        if snapshots.isEmpty {
            guard fileManager.fileExists(atPath: storageURL.path) else {
                return
            }
            try fileManager.removeItem(at: storageURL)
            return
        }

        try fileManager.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            State(
                schemaVersion: Self.currentSchemaVersion,
                snapshots: snapshots
            )
        )
        try data.write(to: storageURL, options: [.atomic])
    }

    private static func pruned(
        _ snapshot: ContextSnapshot,
        at date: Date
    ) -> ContextSnapshot? {
        let contributions = snapshot.contributions.filter {
            $0.expiresAt > date
        }
        guard !contributions.isEmpty else {
            return nil
        }
        return ContextSnapshot(
            providerID: snapshot.providerID,
            observedAt: snapshot.observedAt,
            contributions: contributions
        )
    }
}

private struct State: Codable {
    var schemaVersion: Int
    var snapshots: [ContextSnapshot]
}

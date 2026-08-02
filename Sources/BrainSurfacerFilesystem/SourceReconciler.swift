import BrainSurfacerCore
import Foundation

/// Reconciles one enrolled root while keeping fingerprints aligned with the
/// catalog/index state they describe.
public actor SourceReconciler {
    private let scanner: SourceDirectoryScanner
    private let fingerprintStore: SourceFingerprintStore
    private let coordinator: IndexingCoordinator

    public init(
        scanner: SourceDirectoryScanner = SourceDirectoryScanner(),
        fingerprintStore: SourceFingerprintStore = SourceFingerprintStore(),
        coordinator: IndexingCoordinator
    ) {
        self.scanner = scanner
        self.fingerprintStore = fingerprintStore
        self.coordinator = coordinator
    }

    public func reconcile(_ source: SourceDirectory) async throws -> SourceScanResult {
        let previousFingerprints = await fingerprintStore.fingerprints(
            for: source.url
        )
        let previousEntities = try await coordinator.entities(from: source.url)
        let result = try scanner.scan(
            source,
            previousFingerprints: previousFingerprints,
            previousEntities: previousEntities
        )
        try Task.checkCancellation()

        try await coordinator.replaceEntities(
            from: source.url,
            with: result.entities
        )
        // Fingerprints are disposable optimization state. If this write fails,
        // the catalog and permanent index are still correct; the next pass
        // safely reparses files instead of reporting a false indexing failure.
        try? await fingerprintStore.replaceFingerprints(
            for: source.url,
            with: result.fingerprints
        )
        return result
    }

    public func remove(_ source: SourceDirectory) async throws {
        do {
            try await coordinator.replaceEntities(from: source.url, with: [])
        } catch {
            // The catalog has already journaled the removal if projection
            // application failed. Fingerprints are disposable and should not
            // keep an unenrolled root alive meanwhile.
            try? await fingerprintStore.removeFingerprints(for: source.url)
            throw error
        }
        try? await fingerprintStore.removeFingerprints(for: source.url)
    }
}

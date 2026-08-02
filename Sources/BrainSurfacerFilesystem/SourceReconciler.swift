import BrainSurfacerCore
import Foundation

/// Reconciles one enrolled root while keeping fingerprints aligned with the
/// catalog/index state they describe.
public struct SourceReconciler: Sendable {
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

    public func reconcile(
        _ source: SourceDirectory,
        force: Bool = false
    ) async throws -> SourceScanResult {
        let previousFingerprints = await fingerprintStore.fingerprints(
            for: source.url
        )
        let previousEntities = try await coordinator.entities(from: source.url)
        let scanner = self.scanner
        let result = try await Task.detached(priority: .utility) {
            try scanner.scan(
                source,
                previousFingerprints: previousFingerprints,
                previousEntities: previousEntities,
                force: force
            )
        }.value

        try await coordinator.replaceEntities(
            from: source.url,
            with: result.entities
        )
        try await fingerprintStore.replaceFingerprints(
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

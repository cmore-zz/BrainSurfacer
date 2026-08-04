import BrainSurfacerCore
import Foundation

/// Reconciles enrolled roots one operation at a time, keeping fingerprints
/// aligned with the catalog/index state they describe across async suspension.
public actor SourceReconciler {
    private let scanner: SourceDirectoryScanner
    private let fingerprintStore: SourceFingerprintStore
    private let coordinator: IndexingCoordinator
    private var operationIsRunning = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

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
        await beginOperation()
        defer { endOperation() }
        try Task.checkCancellation()

        if source.indexingMode == .paused {
            let result = SourceScanResult(
                source: source,
                fileCount: 0,
                parsedFileCount: 0,
                entities: [],
                diagnostics: [],
                fingerprints: [:]
            )
            do {
                try await coordinator.replaceEntities(
                    from: source.url,
                    with: [],
                    includeInPermanentIndex: source.discoveryScope
                        .includesPermanentIndex
                )
            } catch {
                try? await fingerprintStore.removeFingerprints(for: source.url)
                throw error
            }
            try await fingerprintStore.removeFingerprints(for: source.url)
            return result
        }

        let previousFingerprints = await fingerprintStore.fingerprints(
            for: source.url
        )
        let previousEntities = try await coordinator.entities(from: source.url)
        let result = try await scanner.scan(
            source,
            previousFingerprints: previousFingerprints,
            previousEntities: previousEntities
        )
        try Task.checkCancellation()

        try await coordinator.replaceEntities(
            from: source.url,
            with: result.entities,
            includeInPermanentIndex: source.discoveryScope.includesPermanentIndex
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
        await beginOperation()
        defer { endOperation() }
        try Task.checkCancellation()

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

    private func beginOperation() async {
        guard operationIsRunning else {
            operationIsRunning = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func endOperation() {
        guard !operationWaiters.isEmpty else {
            operationIsRunning = false
            return
        }
        operationWaiters.removeFirst().resume()
    }
}

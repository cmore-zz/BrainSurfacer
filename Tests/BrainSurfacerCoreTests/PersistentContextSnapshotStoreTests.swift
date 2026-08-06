import BrainSurfacerCore
import BrainSurfacerModel
import Foundation
import Testing

@Test
func persistentContextStoreReplacesEachProviderAndPrunesExpiredContributions() async throws {
    let fixture = ContextStoreFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 10_000)
    let store = PersistentContextSnapshotStore(storageURL: fixture.storageURL)

    try await store.replace(
        snapshot(
            providerID: "org.gnu.Emacs",
            observedAt: now,
            paths: ["First.md", "Expired.md"],
            expirations: [now.addingTimeInterval(60), now]
        ),
        at: now
    )
    try await store.replace(
        snapshot(
            providerID: "org.gnu.Emacs",
            observedAt: now.addingTimeInterval(1),
            paths: ["Second.md"],
            expirations: [now.addingTimeInterval(30)]
        ),
        at: now.addingTimeInterval(1)
    )

    let current = await store.snapshots(at: now.addingTimeInterval(2))
    #expect(current.count == 1)
    #expect(current[0].providerID == "org.gnu.Emacs")
    #expect(current[0].contributions.count == 1)
    #expect(
        current[0].contributions[0].reference
            == .file(URL(fileURLWithPath: "/Second.md"))
    )
    #expect(await store.snapshots(at: now.addingTimeInterval(30)).isEmpty)
}

@Test
func persistentContextStoreSurvivesANewReaderAndCanClearAProvider() async throws {
    let fixture = ContextStoreFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 20_000)
    let writer = PersistentContextSnapshotStore(storageURL: fixture.storageURL)
    try await writer.replace(
        snapshot(
            providerID: "org.gnu.Emacs",
            observedAt: now,
            paths: ["Open.org"],
            expirations: [now.addingTimeInterval(60)]
        ),
        at: now
    )

    let reader = PersistentContextSnapshotStore(storageURL: fixture.storageURL)
    #expect(await reader.snapshots(at: now).count == 1)

    try await writer.removeProvider(identifiedBy: "org.gnu.Emacs", at: now)
    #expect(await reader.snapshots(at: now).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.storageURL.path))
}

@Test
func persistentContextStoreDropsExpiredContributionsDuringAnotherProvidersWrite() async throws {
    let fixture = ContextStoreFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 25_000)
    let store = PersistentContextSnapshotStore(storageURL: fixture.storageURL)
    try await store.replace(
        snapshot(
            providerID: "first",
            observedAt: now,
            paths: ["Expired.md", "Current.md"],
            expirations: [now.addingTimeInterval(1), now.addingTimeInterval(60)]
        ),
        at: now
    )
    try await store.replace(
        snapshot(
            providerID: "second",
            observedAt: now.addingTimeInterval(2),
            paths: ["Other.md"],
            expirations: [now.addingTimeInterval(60)]
        ),
        at: now.addingTimeInterval(2)
    )

    let reader = PersistentContextSnapshotStore(storageURL: fixture.storageURL)
    let snapshots = await reader.snapshots(at: now)
    let first = try #require(snapshots.first { $0.providerID == "first" })
    #expect(first.contributions.count == 1)
    #expect(
        first.contributions[0].reference
            == .file(URL(fileURLWithPath: "/Current.md"))
    )
}

private func snapshot(
    providerID: String,
    observedAt: Date,
    paths: [String],
    expirations: [Date]
) -> ContextSnapshot {
    ContextSnapshot(
        providerID: providerID,
        observedAt: observedAt,
        contributions: zip(paths, expirations).map { path, expiration in
            ContextContribution(
                reference: .file(URL(fileURLWithPath: "/\(path)")),
                relevance: .open,
                expiresAt: expiration
            )
        }
    )
}

private struct ContextStoreFixture {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("BrainSurfacerContextStoreTests-\(UUID().uuidString)")

    var storageURL: URL {
        directoryURL.appendingPathComponent("live-context.json")
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

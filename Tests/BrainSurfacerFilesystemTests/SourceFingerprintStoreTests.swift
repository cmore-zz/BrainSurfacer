import BrainSurfacerFilesystem
import Foundation
import Testing

@Test
func fileFingerprintsPersistPerSourceAndCanBeRemoved() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "BrainSurfacerFingerprints-\(UUID().uuidString)", directoryHint: .isDirectory)
    let storageURL = directory.appending(path: "fingerprints.json")
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let source = URL(fileURLWithPath: "/notes")
    let firstFile = source.appending(path: "First.md")
    let secondFile = source.appending(path: "Second.org")
    let fingerprints = [
        firstFile: SourceFileFingerprint(
            modifiedAt: Date(timeIntervalSince1970: 100),
            fileSize: 10
        ),
        secondFile: SourceFileFingerprint(
            modifiedAt: Date(timeIntervalSince1970: 200),
            fileSize: 20
        )
    ]

    let writer = SourceFingerprintStore(storageURL: storageURL)
    try await writer.replaceFingerprints(for: source, with: fingerprints)

    let relaunched = SourceFingerprintStore(storageURL: storageURL)
    #expect(await relaunched.fingerprints(for: source) == fingerprints)

    try await relaunched.removeFingerprints(for: source)
    #expect(await writer.fingerprints(for: source).isEmpty)
}

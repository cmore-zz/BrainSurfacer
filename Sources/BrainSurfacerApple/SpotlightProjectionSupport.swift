import BrainSurfacerModel
import CryptoKit
import Foundation

enum SpotlightProjection {
    static let schemaVersion = 4

    enum Kind: Equatable {
        case note
        case custom
    }

    static func kind(for entity: KnowledgeEntity) -> Kind {
        entity.kind == .note ? .note : .custom
    }

    static func indexIdentifier(for entityID: EntityID) -> String {
        boundedIdentifier(entityID.rawValue)
    }

    static func tagIdentifier(for name: String) -> String {
        derivedIdentifier(namespace: "notes-tag", value: normalizedTag(name))
    }

    static func folderIdentifier(for url: URL) -> String {
        derivedIdentifier(
            namespace: "notes-folder",
            value: url.standardizedFileURL.path
        )
    }

    static func normalizedTag(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func boundedIdentifier(_ canonicalIdentifier: String) -> String {
        guard canonicalIdentifier.utf8.count > 2_048 else {
            return canonicalIdentifier
        }
        return "sha256:\(digest(canonicalIdentifier))"
    }

    private static func derivedIdentifier(
        namespace: String,
        value: String
    ) -> String {
        "\(namespace):sha256:\(digest(value))"
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct SpotlightProjectionVersionStore: Sendable {
    let storageURL: URL

    init(storageURL: URL = Self.defaultStorageURL()) {
        self.storageURL = storageURL.standardizedFileURL
    }

    static func defaultStorageURL(
        fileManager: FileManager = .default
    ) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("BrainSurfacer", isDirectory: true)
            .appendingPathComponent("spotlight-projection-version", isDirectory: false)
    }

    func storedVersion() -> Int? {
        guard let value = try? String(contentsOf: storageURL, encoding: .utf8) else {
            return nil
        }
        return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func markCurrent(version: Int) throws {
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try String(version).write(
            to: storageURL,
            atomically: true,
            encoding: .utf8
        )
    }
}

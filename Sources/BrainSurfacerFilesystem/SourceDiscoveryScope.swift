import Foundation

/// Controls whether a source stays inside BrainSurfacer or is also donated to
/// Apple's system discovery surfaces.
public enum SourceDiscoveryScope: String, Codable, CaseIterable, Hashable, Sendable {
    case localAndApple
    case localOnly

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        // Unknown future sharing scopes must not broaden external enrollment.
        self = Self(rawValue: rawValue) ?? .localOnly
    }

    var includesPermanentIndex: Bool {
        self == .localAndApple
    }
}

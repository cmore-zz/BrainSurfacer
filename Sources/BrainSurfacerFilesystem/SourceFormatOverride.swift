import Foundation

public struct SourceFormatOverride: Codable, Hashable, Identifiable, Sendable {
    public enum Target: String, CaseIterable, Codable, Sendable {
        case automatic
        case markdown
        case org
        case bbcode

        public init(_ format: SourceDocument.Format) {
            switch format {
            case .markdown:
                self = .markdown
            case .org:
                self = .org
            case .bbcode:
                self = .bbcode
            }
        }

        public var format: SourceDocument.Format? {
            switch self {
            case .automatic:
                nil
            case .markdown:
                .markdown
            case .org:
                .org
            case .bbcode:
                .bbcode
            }
        }
    }

    public var id: String { suffix }
    public let suffix: String
    public let target: Target

    public init?(suffix rawSuffix: String, format: SourceDocument.Format) {
        self.init(suffix: rawSuffix, target: Target(format))
    }

    public init?(suffix rawSuffix: String, target: Target) {
        guard let suffix = Self.normalizedSuffix(rawSuffix) else {
            return nil
        }
        self.suffix = suffix
        self.target = target
    }

    public static func normalized(
        _ overrides: [SourceFormatOverride]
    ) -> [SourceFormatOverride] {
        var bySuffix: [String: SourceFormatOverride] = [:]
        for override in overrides {
            bySuffix[override.suffix] = override
        }
        return bySuffix.values.sorted { $0.suffix < $1.suffix }
    }

    public static func normalizedSuffix(_ rawSuffix: String) -> String? {
        var suffix = rawSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !suffix.isEmpty else {
            return nil
        }
        if !suffix.hasPrefix(".") {
            suffix = "." + suffix
        }
        guard suffix.count > 1,
              suffix.dropFirst().contains(where: { $0.isLetter || $0.isNumber }),
              suffix.allSatisfy({
                  $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_"
              }) else {
            return nil
        }
        return suffix
    }

    private enum CodingKeys: String, CodingKey {
        case suffix
        case format
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawSuffix = try values.decode(String.self, forKey: .suffix)
        let target = try values.decode(Target.self, forKey: .format)
        guard let normalized = Self(suffix: rawSuffix, target: target) else {
            throw DecodingError.dataCorruptedError(
                forKey: .suffix,
                in: values,
                debugDescription: "Invalid source-format suffix"
            )
        }
        self = normalized
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(suffix, forKey: .suffix)
        try values.encode(target, forKey: .format)
    }
}

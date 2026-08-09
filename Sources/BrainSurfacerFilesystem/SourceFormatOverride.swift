import Foundation

public struct SourceFormatOverride: Codable, Hashable, Identifiable, Sendable {
    public var id: String { suffix }
    public let suffix: String
    public let format: SourceDocument.Format

    public init?(suffix rawSuffix: String, format: SourceDocument.Format) {
        guard let suffix = Self.normalizedSuffix(rawSuffix) else {
            return nil
        }
        self.suffix = suffix
        self.format = format
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
        let format = try values.decode(SourceDocument.Format.self, forKey: .format)
        guard let normalized = Self(suffix: rawSuffix, format: format) else {
            throw DecodingError.dataCorruptedError(
                forKey: .suffix,
                in: values,
                debugDescription: "Invalid source-format suffix"
            )
        }
        self = normalized
    }
}

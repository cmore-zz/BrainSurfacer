import Foundation

/// Root-relative glob rules controlling which files an enrolled source scans.
/// An empty include list admits every supported file; exclusions always win.
public struct SourcePathPolicy: Codable, Hashable, Sendable {
    public let includePatterns: [String]
    public let excludePatterns: [String]

    public init(
        includePatterns: [String] = [],
        excludePatterns: [String] = []
    ) {
        self.includePatterns = Self.normalizedPatterns(includePatterns)
        self.excludePatterns = Self.normalizedPatterns(excludePatterns)
    }

    public var isUnrestricted: Bool {
        includePatterns.isEmpty && excludePatterns.isEmpty
    }

    public func includes(relativePath: String) -> Bool {
        let relativePath = Self.normalizedPath(relativePath)
        guard !relativePath.isEmpty else {
            return false
        }

        let isIncluded = includePatterns.isEmpty
            || includePatterns.contains { Self.matches($0, path: relativePath) }
        guard isIncluded else {
            return false
        }
        return !excludePatterns.contains { Self.matches($0, path: relativePath) }
    }

    private enum CodingKeys: String, CodingKey {
        case includePatterns
        case excludePatterns
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            includePatterns: try values.decodeIfPresent(
                [String].self,
                forKey: .includePatterns
            ) ?? [],
            excludePatterns: try values.decodeIfPresent(
                [String].self,
                forKey: .excludePatterns
            ) ?? []
        )
    }

    private static func normalizedPatterns(_ patterns: [String]) -> [String] {
        var seen: Set<String> = []
        return patterns.compactMap { rawPattern in
            let trimmedPattern = rawPattern.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            var pattern = normalizedPath(rawPattern)
            if trimmedPattern.hasSuffix("/") {
                pattern = pattern.isEmpty ? "**" : pattern + "/**"
            }
            let components = pattern.split(separator: "/").map(String.init)
            pattern = components.reduce(into: [String]()) { result, component in
                if component != "**" || result.last != "**" {
                    result.append(component)
                }
            }
            .joined(separator: "/")
            guard !pattern.isEmpty, seen.insert(pattern).inserted else {
                return nil
            }
            return pattern
        }
    }

    private static func normalizedPath(_ rawPath: String) -> String {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.hasPrefix("./") {
            path.removeFirst(2)
        }
        while path.hasPrefix("/") {
            path.removeFirst()
        }
        while path.contains("//") {
            path = path.replacingOccurrences(of: "//", with: "/")
        }
        while path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private static func matches(_ pattern: String, path: String) -> Bool {
        let patternComponents = pattern.split(separator: "/").map(String.init)
        let pathComponents = path.split(separator: "/").map(String.init)
        var failedMatches: Set<PathMatchPosition> = []

        func match(patternIndex: Int, pathIndex: Int) -> Bool {
            if patternIndex == patternComponents.count {
                return pathIndex == pathComponents.count
            }
            let position = PathMatchPosition(
                patternIndex: patternIndex,
                pathIndex: pathIndex
            )
            if failedMatches.contains(position) {
                return false
            }

            let component = patternComponents[patternIndex]
            if component == "**" {
                if match(patternIndex: patternIndex + 1, pathIndex: pathIndex)
                    || (pathIndex < pathComponents.count
                        && match(patternIndex: patternIndex, pathIndex: pathIndex + 1)) {
                    return true
                }
            } else if pathIndex < pathComponents.count,
                      matchesComponent(component, value: pathComponents[pathIndex]),
                      match(patternIndex: patternIndex + 1, pathIndex: pathIndex + 1) {
                return true
            }

            failedMatches.insert(position)
            return false
        }

        return match(patternIndex: 0, pathIndex: 0)
    }

    private static func matchesComponent(_ pattern: String, value: String) -> Bool {
        let patternCharacters = Array(pattern)
        let valueCharacters = Array(value)
        var failedMatches: Set<ComponentMatchPosition> = []

        func match(patternIndex: Int, valueIndex: Int) -> Bool {
            if patternIndex == patternCharacters.count {
                return valueIndex == valueCharacters.count
            }
            let position = ComponentMatchPosition(
                patternIndex: patternIndex,
                valueIndex: valueIndex
            )
            if failedMatches.contains(position) {
                return false
            }

            let character = patternCharacters[patternIndex]
            if character == "*" {
                if match(patternIndex: patternIndex + 1, valueIndex: valueIndex)
                    || (valueIndex < valueCharacters.count
                        && match(patternIndex: patternIndex, valueIndex: valueIndex + 1)) {
                    return true
                }
            } else if valueIndex < valueCharacters.count,
                      (character == "?" || character == valueCharacters[valueIndex]),
                      match(patternIndex: patternIndex + 1, valueIndex: valueIndex + 1) {
                return true
            }

            failedMatches.insert(position)
            return false
        }

        return match(patternIndex: 0, valueIndex: 0)
    }
}

private struct PathMatchPosition: Hashable {
    let patternIndex: Int
    let pathIndex: Int
}

private struct ComponentMatchPosition: Hashable {
    let patternIndex: Int
    let valueIndex: Int
}

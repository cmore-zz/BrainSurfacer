import BrainSurfacerModel
import Foundation

public enum BrainSurfacerDeepLink: Equatable, Sendable {
    public static let scheme = "brainsurfacer"

    case entity(EntityID)
    case search(String)

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "open"

        switch self {
        case let .entity(identifier):
            components.path = "/entity"
            components.queryItems = [
                URLQueryItem(name: "id", value: identifier.rawValue)
            ]
        case let .search(term):
            components.path = "/search"
            components.queryItems = [
                URLQueryItem(name: "query", value: term)
            ]
        }

        guard let url = components.url else {
            preconditionFailure("BrainSurfacer constructed an invalid deep link")
        }
        return url
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              url.host?.lowercased() == "open",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let queryItems = components.queryItems ?? []
        switch components.path {
        case "/entity":
            guard let value = queryItems.first(where: { $0.name == "id" })?.value,
                  !value.isEmpty else {
                return nil
            }
            self = .entity(EntityID(rawValue: value))
        case "/search":
            guard let value = queryItems.first(where: { $0.name == "query" })?.value else {
                return nil
            }
            self = .search(value)
        default:
            return nil
        }
    }
}

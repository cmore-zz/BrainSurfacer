import BrainSurfacerModel
import Foundation

public enum BrainSurfacerDeepLink: Equatable, Sendable {
    public static let scheme = "brainsurfacer"

    case entity(EntityID)
    case search(String)
    case context(EditorContextUpdate)

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
        case let .context(update):
            let data: Data
            do {
                data = try JSONEncoder().encode(update)
            } catch {
                preconditionFailure("BrainSurfacer could not encode editor context")
            }
            components.path = "/context"
            components.queryItems = [
                URLQueryItem(name: "payload", value: data.base64URLEncodedString)
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
        case "/context":
            guard let value = queryItems.first(where: { $0.name == "payload" })?.value,
                  value.utf8.count <= 32_768,
                  let data = Data(base64URLEncoded: value),
                  let update = try? JSONDecoder().decode(
                      EditorContextUpdate.self,
                      from: data
                  ) else {
                return nil
            }
            self = .context(update)
        default:
            return nil
        }
    }
}

private extension Data {
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded value: String) {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        self.init(base64Encoded: base64)
    }
}

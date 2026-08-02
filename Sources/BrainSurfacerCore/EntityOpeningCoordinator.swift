import BrainSurfacerModel
import Foundation

public enum EntityOpeningError: LocalizedError, Equatable, Sendable {
    case entityNotFound
    case noCompatibleOpener(URL)
    case allOpenersFailed(URL, String)
    case failureAlreadyPresented(URL)

    public var errorDescription: String? {
        switch self {
        case .entityNotFound:
            "That knowledge item is no longer available. Reindex its source and try again."
        case let .noCompatibleOpener(url):
            "No configured application can open \(url.path(percentEncoded: false))."
        case let .allOpenersFailed(url, message):
            "Couldn’t open \(url.lastPathComponent): \(message)"
        case let .failureAlreadyPresented(url):
            "macOS could not open \(url.lastPathComponent)."
        }
    }
}

public struct EntityOpeningCoordinator: Sendable {
    private let catalog: any EntityCatalog
    private let openers: [any DocumentOpener]

    public init(
        catalog: any EntityCatalog,
        openers: [any DocumentOpener]
    ) {
        self.catalog = catalog
        self.openers = openers
    }

    @discardableResult
    public func open(_ reference: EntityReference) async throws -> KnowledgeEntity {
        guard let entity = try await catalog.resolve(reference) else {
            throw EntityOpeningError.entityNotFound
        }

        var lastFailureDescription: String?
        var wasLastFailurePresented = false
        for opener in openers where await opener.canOpen(entity) {
            do {
                try await opener.open(entity)
                return entity
            } catch {
                lastFailureDescription = error.localizedDescription
                wasLastFailurePresented = error is any UserPresentedDocumentOpeningError
            }
        }

        if let lastFailureDescription {
            if wasLastFailurePresented {
                throw EntityOpeningError.failureAlreadyPresented(
                    entity.source.fileURL
                )
            }
            throw EntityOpeningError.allOpenersFailed(
                entity.source.fileURL,
                lastFailureDescription
            )
        }
        throw EntityOpeningError.noCompatibleOpener(entity.source.fileURL)
    }
}

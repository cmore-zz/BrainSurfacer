import BrainSurfacerModel
import Foundation

public actor IndexingCoordinator {
    private let catalog: any EntityCatalog
    private let permanentIndex: any PermanentEntityIndex

    public init(
        catalog: any EntityCatalog,
        permanentIndex: any PermanentEntityIndex
    ) {
        self.catalog = catalog
        self.permanentIndex = permanentIndex
    }

    public func replaceEntities(
        from source: URL,
        with entities: [KnowledgeEntity]
    ) async throws {
        let change = try await catalog.replaceEntities(from: source, with: entities)
        try await permanentIndex.apply(change)
    }
}

import BrainSurfacerModel
import Foundation

public actor InMemoryEntityCatalog: EntityCatalog {
    private var entitiesByID: [EntityID: KnowledgeEntity] = [:]
    private var identifiersBySource: [URL: Set<EntityID>] = [:]
    private var providerReferences: [ProviderReference: EntityID] = [:]

    public init() {}

    public func replaceEntities(
        from source: URL,
        with entities: [KnowledgeEntity]
    ) -> EntityIndexChange {
        let source = source.standardizedFileURL
        let previousSource = EntityIdentityStabilizer.movedSourceCandidate(
            for: source,
            incoming: entities,
            identifiersBySource: identifiersBySource,
            entitiesByID: entitiesByID
        ) ?? source
        let previous = identifiersBySource[previousSource, default: []]
        let previousEntities = previous.compactMap { entitiesByID[$0] }
        let entities = EntityIdentityStabilizer.stabilize(
            entities,
            against: previousEntities
        )
        let next = Set(entities.map(\.id))
        let removals = previous.subtracting(next)

        for identifier in removals {
            entitiesByID.removeValue(forKey: identifier)
        }
        for entity in entities {
            entitiesByID[entity.id] = entity
        }
        if previousSource != source {
            identifiersBySource.removeValue(forKey: previousSource)
        }
        identifiersBySource[source] = next

        return EntityIndexChange(upserts: entities, removals: removals)
    }

    public func entities(identifiedBy identifiers: [EntityID]) -> [KnowledgeEntity] {
        identifiers.compactMap { entitiesByID[$0] }
    }

    public func entities(from source: URL) async -> [KnowledgeEntity] {
        identifiersBySource[source.standardizedFileURL, default: []]
            .compactMap { entitiesByID[$0] }
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public func allEntities() -> [KnowledgeEntity] {
        entitiesByID.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public func resolve(_ reference: EntityReference) -> KnowledgeEntity? {
        switch reference {
        case let .entityID(identifier):
            return entitiesByID[identifier]

        case let .file(fileURL):
            return candidates(for: fileURL)
                .first(where: { $0.kind == .note })
                ?? candidates(for: fileURL).first

        case let .sourceAnchor(anchor):
            let fileCandidates = candidates(for: anchor.fileURL)

            if let editorIdentifier = anchor.editorIdentifier {
                if let match = fileCandidates.first(where: {
                    $0.source.editorIdentifier == editorIdentifier
                }) {
                    return match
                }
            }

            if !anchor.headingPath.isEmpty {
                if let match = fileCandidates.first(where: {
                    $0.source.headingPath == anchor.headingPath
                }) {
                    return match
                }
            }

            if let line = anchor.line {
                if let match = fileCandidates.first(where: {
                    $0.source.line == line
                }) {
                    return match
                }
            }

            return fileCandidates.first(where: { $0.kind == .note })
                ?? fileCandidates.first

        case let .providerLocal(providerID, value):
            guard let identifier = providerReferences[
                ProviderReference(providerID: providerID, value: value)
            ] else {
                return nil
            }
            return entitiesByID[identifier]
        }
    }

    public func registerProviderReference(
        providerID: String,
        value: String,
        for identifier: EntityID
    ) {
        providerReferences[
            ProviderReference(providerID: providerID, value: value)
        ] = identifier
    }

    private func candidates(for fileURL: URL) -> [KnowledgeEntity] {
        let standardizedURL = fileURL.standardizedFileURL
        return entitiesByID.values
            .filter { $0.source.fileURL.standardizedFileURL == standardizedURL }
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private struct ProviderReference: Hashable {
        var providerID: String
        var value: String
    }
}

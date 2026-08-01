import BrainSurfacerModel
import CryptoKit
import Foundation

struct EntityIdentityStabilizer {
    static func movedSourceCandidate(
        for source: URL,
        incoming: [KnowledgeEntity],
        identifiersBySource: [URL: Set<EntityID>],
        entitiesByID: [EntityID: KnowledgeEntity],
        fileManager: FileManager = .default
    ) -> URL? {
        let source = source.standardizedFileURL
        guard identifiersBySource[source] == nil,
              let signature = documentSignature(incoming),
              !signature.isEmpty else {
            return nil
        }

        let candidates = identifiersBySource.compactMap { candidate, identifiers -> URL? in
            guard candidate != source,
                  !fileManager.fileExists(atPath: candidate.path) else {
                return nil
            }
            let entities = identifiers.compactMap { entitiesByID[$0] }
            return documentSignature(entities) == signature ? candidate : nil
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    static func stabilize(
        _ incoming: [KnowledgeEntity],
        against previous: [KnowledgeEntity]
    ) -> [KnowledgeEntity] {
        var assignments: [Int: EntityID] = [:]
        var identifierRemapping: [EntityID: EntityID] = [:]
        var claimedPreviousIdentifiers: Set<EntityID> = []
        var previousDocumentByIncomingDocument: [URL: URL] = [:]

        let orderedIndices = incoming.indices.filter { incoming[$0].kind == .note }
            + incoming.indices.filter { incoming[$0].kind != .note }

        for index in orderedIndices {
            let entity = incoming[index]
            guard entity.observedIdentifier != nil else {
                assignments[index] = entity.id
                identifierRemapping[entity.id] = entity.id
                if previous.contains(where: { $0.id == entity.id }) {
                    claimedPreviousIdentifiers.insert(entity.id)
                }
                continue
            }

            if entity.hasGlobalExplicitIdentifier {
                assignments[index] = entity.id
                identifierRemapping[entity.id] = entity.id
                claimedPreviousIdentifiers.insert(entity.id)
                continue
            }

            let available = previous.filter {
                !claimedPreviousIdentifiers.contains($0.id)
                    && identityClass(for: $0.kind) == identityClass(for: entity.kind)
            }
            let matched = match(
                entity,
                at: index,
                incoming: incoming,
                candidates: available,
                previousDocumentByIncomingDocument: previousDocumentByIncomingDocument
            )
            let canonicalIdentifier = matched?.id ?? canonicalIdentifier(for: entity)
            assignments[index] = canonicalIdentifier
            identifierRemapping[entity.id] = canonicalIdentifier

            if let matched {
                claimedPreviousIdentifiers.insert(matched.id)
                if entity.kind == .note {
                    previousDocumentByIncomingDocument[
                        entity.source.fileURL.standardizedFileURL
                    ] = matched.source.fileURL.standardizedFileURL
                }
            }
        }

        return incoming.indices.map { index in
            var entity = incoming[index]
            entity.id = assignments[index] ?? entity.id
            entity.relationships = entity.relationships.map { relationship in
                var relationship = relationship
                relationship.target = identifierRemapping[relationship.target]
                    ?? relationship.target
                return relationship
            }
            return entity
        }
    }

    private static func match(
        _ entity: KnowledgeEntity,
        at index: Int,
        incoming: [KnowledgeEntity],
        candidates: [KnowledgeEntity],
        previousDocumentByIncomingDocument: [URL: URL]
    ) -> KnowledgeEntity? {
        let incomingDocument = entity.source.fileURL.standardizedFileURL
        let previousDocument = previousDocumentByIncomingDocument[incomingDocument]

        if entity.kind != .note,
           let explicitIdentifier = entity.explicitIdentifier {
            let matches = candidates.filter {
                $0.explicitIdentifier == explicitIdentifier
            }
            if let match = chooseMatch(
                from: matches,
                entity: entity,
                at: index,
                incoming: incoming,
                previousDocument: previousDocument,
                key: { $0.explicitIdentifier }
            ) {
                return match
            }
        }

        if let observedIdentifier = entity.observedIdentifier,
           let match = candidates.first(where: {
               $0.observedIdentifier == observedIdentifier
           }) {
            return match
        }

        guard let fingerprint = entity.structuralFingerprint else {
            return nil
        }
        let matches = candidates.filter {
            $0.structuralFingerprint == fingerprint
        }
        return chooseMatch(
            from: matches,
            entity: entity,
            at: index,
            incoming: incoming,
            previousDocument: previousDocument,
            key: { $0.structuralFingerprint }
        )
    }

    private static func chooseMatch(
        from candidates: [KnowledgeEntity],
        entity: KnowledgeEntity,
        at index: Int,
        incoming: [KnowledgeEntity],
        previousDocument: URL?,
        key: (KnowledgeEntity) -> String?
    ) -> KnowledgeEntity? {
        if let previousDocument {
            let scoped = candidates
                .filter { $0.source.fileURL.standardizedFileURL == previousDocument }
                .sorted(by: sourceOrder)
            if scoped.count == 1 {
                return scoped[0]
            }
            if !scoped.isEmpty,
               let matchKey = key(entity) {
                let incomingPeers = incoming.indices
                    .filter {
                        incoming[$0].source.fileURL.standardizedFileURL
                            == entity.source.fileURL.standardizedFileURL
                            && identityClass(for: incoming[$0].kind)
                                == identityClass(for: entity.kind)
                            && key(incoming[$0]) == matchKey
                    }
                    .sorted { sourceOrder(incoming[$0], incoming[$1]) }
                if let ordinal = incomingPeers.firstIndex(of: index),
                   ordinal < scoped.count {
                    return scoped[ordinal]
                }
            }
        }

        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func sourceOrder(
        _ lhs: KnowledgeEntity,
        _ rhs: KnowledgeEntity
    ) -> Bool {
        let lhsLine = lhs.source.line ?? 0
        let rhsLine = rhs.source.line ?? 0
        if lhsLine != rhsLine {
            return lhsLine < rhsLine
        }
        return lhs.id.rawValue < rhs.id.rawValue
    }

    private static func canonicalIdentifier(for entity: KnowledgeEntity) -> EntityID {
        guard let observedIdentifier = entity.observedIdentifier else {
            return entity.id
        }
        let digest = SHA256.hash(data: Data(observedIdentifier.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return EntityID(rawValue: "entity:\(digest)")
    }

    private static func identityClass(
        for kind: KnowledgeEntity.Kind
    ) -> IdentityClass {
        switch kind {
        case .note:
            .document
        case .heading, .section, .block, .task:
            .outline
        default:
            .semantic(kind)
        }
    }

    private static func documentSignature(
        _ entities: [KnowledgeEntity]
    ) -> [String]? {
        let fingerprints = entities
            .filter { $0.kind == .note }
            .compactMap(\.structuralFingerprint)
            .sorted()
        return fingerprints.isEmpty ? nil : fingerprints
    }
}

private extension EntityIdentityStabilizer {
    enum IdentityClass: Equatable {
        case document
        case outline
        case semantic(KnowledgeEntity.Kind)
    }
}

private extension KnowledgeEntity {
    var observedIdentifier: String? {
        attributes[EntityIdentityMetadata.observedIdentifier]
    }

    var explicitIdentifier: String? {
        attributes[EntityIdentityMetadata.explicitIdentifier]
    }

    var structuralFingerprint: String? {
        attributes[EntityIdentityMetadata.structuralFingerprint]
    }

    var hasGlobalExplicitIdentifier: Bool {
        guard let explicitIdentifier else {
            return false
        }
        return explicitIdentifier.hasPrefix("org-id:")
            && id.rawValue == explicitIdentifier
    }
}

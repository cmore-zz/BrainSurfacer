import BrainSurfacerModel
import Foundation

/// Controls how much durable, searchable information an enrolled source emits.
public enum SourceIndexingMode: String, Codable, CaseIterable, Hashable, Sendable {
    case fullContent
    case metadataOnly
    case paused

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        // A newer, unknown privacy mode must never broaden indexing in an
        // older reader. Pausing is the safe forward-compatible fallback.
        self = Self(rawValue: rawValue) ?? .paused
    }

    func applying(to entities: [KnowledgeEntity]) -> [KnowledgeEntity] {
        switch self {
        case .fullContent:
            entities
        case .metadataOnly:
            entities.map { entity in
                var entity = entity
                entity.body = nil
                entity.summary = nil
                entity.links = []
                entity.relationships.removeAll { relationship in
                    switch relationship.kind {
                    case .parent, .child, .belongsTo:
                        false
                    case .linksTo, .mentions, .attachedTo:
                        true
                    }
                }
                entity.attributes = entity.attributes.filter {
                    Self.metadataOnlyAttributeKeys.contains($0.key)
                }
                return entity
            }
        case .paused:
            []
        }
    }

    private static let metadataOnlyAttributeKeys: Set<String> = [
        "taskState",
        EntityIdentityMetadata.observedIdentifier,
        EntityIdentityMetadata.explicitIdentifier,
        EntityIdentityMetadata.structuralFingerprint
    ]
}

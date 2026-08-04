import AppIntents
import BrainSurfacerModel

/// Maps canonical entities to the same App Entity identity used by Spotlight.
/// UI annotations must not invent a second identifier namespace.
public enum BrainSurfacerAppEntityAnnotations {
    public static func identifier(for entity: KnowledgeEntity) -> EntityIdentifier {
        if entity.kind == .note {
            return EntityIdentifier(for: SpotlightNoteEntity(entity))
        }
        return EntityIdentifier(for: SpotlightKnowledgeEntity(entity))
    }
}

import AppIntents
import BrainSurfacerCore
import BrainSurfacerModel

/// Maps canonical entities to the same App Entity identity used by Spotlight.
/// UI annotations must not invent a second identifier namespace.
public enum BrainSurfacerAppEntityAnnotations {
    /// Identifies the expiring aggregate rather than embedding its current
    /// contents in the SwiftUI hierarchy. The entity query remains responsible
    /// for enforcing expiry and Apple-discovery scope when the system resolves
    /// the identifier.
    public static func identifier(for context: CurrentContext) -> EntityIdentifier? {
        guard !context.resolved.isEmpty else { return nil }
        return EntityIdentifier(
            for: SpotlightLiveContextEntity.self,
            identifier: SpotlightLiveContextEntity.currentIdentifier
        )
    }

    public static func identifier(for entity: KnowledgeEntity) -> EntityIdentifier {
        if entity.kind == .note {
            return EntityIdentifier(for: SpotlightNoteEntity(entity))
        }
        return EntityIdentifier(for: SpotlightKnowledgeEntity(entity))
    }
}

import Foundation

public actor FakeContextProvider: ContextProvider {
    public nonisolated let id: String
    private var snapshot: ContextSnapshot

    public init(
        id: String = "dev.brainsurfacer.fake",
        observedAt: Date = Date(),
        contributions: [ContextContribution] = []
    ) {
        self.id = id
        snapshot = ContextSnapshot(
            providerID: id,
            observedAt: observedAt,
            contributions: contributions
        )
    }

    public func contextSnapshot() -> ContextSnapshot {
        snapshot
    }

    public func update(
        observedAt: Date = Date(),
        contributions: [ContextContribution]
    ) {
        snapshot = ContextSnapshot(
            providerID: id,
            observedAt: observedAt,
            contributions: contributions
        )
    }
}

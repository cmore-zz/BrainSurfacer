import BrainSurfacerModel
import Foundation

public actor ContextCoordinator {
    public enum Error: Swift.Error, Equatable {
        case providerIdentityMismatch(expected: String, received: String)
    }

    private let catalog: any EntityCatalog
    private let rankingPolicy: any ContextRankingPolicy
    private var snapshotsByProvider: [String: ContextSnapshot] = [:]

    public init(
        catalog: any EntityCatalog,
        rankingPolicy: any ContextRankingPolicy = DefaultContextRankingPolicy()
    ) {
        self.catalog = catalog
        self.rankingPolicy = rankingPolicy
    }

    public func refresh(from provider: any ContextProvider) async throws {
        let snapshot = try await provider.contextSnapshot()
        guard snapshot.providerID == provider.id else {
            throw Error.providerIdentityMismatch(
                expected: provider.id,
                received: snapshot.providerID
            )
        }
        ingest(snapshot)
    }

    public func ingest(_ snapshot: ContextSnapshot) {
        snapshotsByProvider[snapshot.providerID] = snapshot
    }

    public func removeProvider(identifiedBy providerID: String) {
        snapshotsByProvider.removeValue(forKey: providerID)
    }

    public func currentContext(at date: Date = Date()) async throws -> CurrentContext {
        pruneExpiredContributions(at: date)

        var entityByID: [EntityID: KnowledgeEntity] = [:]
        var signalsByEntityID: [EntityID: [ContextSignal]] = [:]
        var unresolved: [UnresolvedContextContribution] = []

        for snapshot in snapshotsByProvider.values {
            for contribution in snapshot.contributions {
                guard contribution.expiresAt > date else {
                    continue
                }

                guard let entity = try await catalog.resolve(contribution.reference) else {
                    unresolved.append(
                        UnresolvedContextContribution(
                            providerID: snapshot.providerID,
                            observedAt: snapshot.observedAt,
                            contribution: contribution
                        )
                    )
                    continue
                }

                entityByID[entity.id] = entity
                signalsByEntityID[entity.id, default: []].append(
                    ContextSignal(
                        providerID: snapshot.providerID,
                        relevance: contribution.relevance,
                        observedAt: snapshot.observedAt,
                        expiresAt: contribution.expiresAt
                    )
                )
            }
        }

        let resolved = entityByID.values.map { entity in
            let signals = signalsByEntityID[entity.id, default: []].sorted {
                if $0.observedAt != $1.observedAt {
                    return $0.observedAt > $1.observedAt
                }
                return $0.providerID < $1.providerID
            }
            return ResolvedContextItem(
                entity: entity,
                signals: signals,
                score: rankingPolicy.score(for: signals)
            )
        }.sorted {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return $0.entity.id.rawValue < $1.entity.id.rawValue
        }

        unresolved.sort {
            if $0.providerID != $1.providerID {
                return $0.providerID < $1.providerID
            }
            return String(describing: $0.contribution.reference)
                < String(describing: $1.contribution.reference)
        }

        return CurrentContext(resolved: resolved, unresolved: unresolved)
    }

    private func pruneExpiredContributions(at date: Date) {
        for providerID in Array(snapshotsByProvider.keys) {
            guard var snapshot = snapshotsByProvider[providerID] else {
                continue
            }
            snapshot.contributions.removeAll { $0.expiresAt <= date }
            if snapshot.contributions.isEmpty {
                snapshotsByProvider.removeValue(forKey: providerID)
            } else {
                snapshotsByProvider[providerID] = snapshot
            }
        }
    }
}

public struct DefaultContextRankingPolicy: ContextRankingPolicy {
    public init() {}

    public func score(for signals: [ContextSignal]) -> Int {
        signals.map { signal in
            switch signal.relevance {
            case .selected: 120
            case .visible: 110
            case .currentTask: 100
            case .activeProject: 90
            case .open: 80
            case .neighboring: 60
            case .recent: 40
            }
        }.max() ?? 0
    }
}

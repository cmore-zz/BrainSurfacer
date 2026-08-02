import Foundation

/// Debounces filesystem notifications and guarantees that its handler never
/// runs more than once at a time.
public actor SourceChangeCoalescer {
    public typealias Handler = @Sendable (Set<URL>) async -> Void

    private let delay: Duration
    private let handler: Handler
    private var pendingSourceURLs: Set<URL> = []
    private var debounceTask: Task<Void, Never>?
    private var isHandling = false

    public init(
        delay: Duration = .milliseconds(500),
        handler: @escaping Handler
    ) {
        self.delay = delay
        self.handler = handler
    }

    public func submit(_ sourceURLs: Set<URL>) {
        guard !sourceURLs.isEmpty else {
            return
        }
        pendingSourceURLs.formUnion(sourceURLs.map(\.standardizedFileURL))
        scheduleDebounce()
    }

    public func cancel() {
        debounceTask?.cancel()
        debounceTask = nil
        pendingSourceURLs.removeAll()
    }

    private func scheduleDebounce() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self, delay] in
            do {
                try await Task.sleep(for: delay)
                await self?.drain()
            } catch is CancellationError {
                // A later event restarted the debounce window.
            } catch {
                // ContinuousClock.sleep currently only throws cancellation.
            }
        }
    }

    private func drain() async {
        debounceTask = nil
        guard !isHandling, !pendingSourceURLs.isEmpty else {
            return
        }

        let sourceURLs = pendingSourceURLs
        pendingSourceURLs.removeAll()
        isHandling = true
        await handler(sourceURLs)
        isHandling = false

        // Events received while the handler was suspended get a fresh debounce
        // window instead of starting a concurrent reconciliation.
        if !pendingSourceURLs.isEmpty {
            scheduleDebounce()
        }
    }
}

@testable import BrainSurfacerFilesystem
import Foundation
import Testing

@Test
func sourceChangesWithinDebounceWindowAreCombined() async throws {
    let recorder = SourceChangeRecorder()
    let coalescer = SourceChangeCoalescer(delay: .milliseconds(20)) { sourceURLs in
        await recorder.record(sourceURLs)
    }
    let first = URL(fileURLWithPath: "/notes/first")
    let second = URL(fileURLWithPath: "/notes/second")

    await coalescer.submit([first])
    await coalescer.submit([second])
    try await waitUntil { await recorder.batchCount == 1 }

    #expect(await recorder.batches == [[first, second]])
}

@Test
func sourceChangesReceivedDuringHandlingWaitForAnotherPass() async throws {
    let recorder = SourceChangeRecorder(handlerDelay: .milliseconds(60))
    let coalescer = SourceChangeCoalescer(delay: .milliseconds(10)) { sourceURLs in
        await recorder.record(sourceURLs)
    }
    let first = URL(fileURLWithPath: "/notes/first")
    let second = URL(fileURLWithPath: "/notes/second")
    let third = URL(fileURLWithPath: "/notes/third")

    await coalescer.submit([first])
    try await waitUntil { await recorder.batchCount == 1 }
    await coalescer.submit([second])
    await coalescer.submit([third])
    try await waitUntil { await recorder.batchCount == 2 }
    try await waitUntil { await recorder.activeHandlerCount == 0 }

    #expect(await recorder.batches == [[first], [second, third]])
    #expect(await recorder.maximumActiveHandlerCount == 1)
}

@Test
func cancelledSourceChangesDoNotReachHandler() async throws {
    let recorder = SourceChangeRecorder()
    let coalescer = SourceChangeCoalescer(delay: .milliseconds(40)) { sourceURLs in
        await recorder.record(sourceURLs)
    }

    await coalescer.submit([URL(fileURLWithPath: "/notes")])
    await coalescer.cancel()
    try await Task.sleep(for: .milliseconds(80))

    #expect(await recorder.batches.isEmpty)
}

@Test
func filesystemEventsAffectEveryEnclosingSourceRoot() {
    let notes = URL(fileURLWithPath: "/library/notes")
    let project = notes.appending(path: "project", directoryHint: .isDirectory)
    let elsewhere = URL(fileURLWithPath: "/library/elsewhere")
    let changedFile = project.appending(path: "Plan.md")

    let affected = FSEventsSourceObserver.affectedSourceURLs(
        for: [changedFile],
        among: [notes, project, elsewhere]
    )

    #expect(affected == [notes, project])
}

private actor SourceChangeRecorder {
    private(set) var batches: [Set<URL>] = []
    private(set) var activeHandlerCount = 0
    private(set) var maximumActiveHandlerCount = 0
    private let handlerDelay: Duration

    init(handlerDelay: Duration = .zero) {
        self.handlerDelay = handlerDelay
    }

    var batchCount: Int {
        batches.count
    }

    func record(_ sourceURLs: Set<URL>) async {
        activeHandlerCount += 1
        maximumActiveHandlerCount = max(
            maximumActiveHandlerCount,
            activeHandlerCount
        )
        batches.append(sourceURLs)
        try? await Task.sleep(for: handlerDelay)
        activeHandlerCount -= 1
    }
}

private struct SourceChangeTimeout: Error {}

private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw SourceChangeTimeout()
}

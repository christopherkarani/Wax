import Foundation
import Testing
@testable import WaxCore

private actor OperationProbe {
    private(set) var observedCancellation = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var started = false

    func markStarted() {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func markCancelled() {
        observedCancellation = true
    }
}

@Test(.timeLimit(.minutes(1)))
func asyncTimeoutPropagatesCallerCancellationToOperation() async throws {
    let probe = OperationProbe()
    let caller = Task {
        try await AsyncTimeout.run(timeout: .seconds(600), operation: "cancellation-propagation") {
            await probe.markStarted()
            do {
                try await Task.sleep(for: .seconds(600))
            } catch is CancellationError {
                await probe.markCancelled()
                throw CancellationError()
            }
            return 1
        }
    }

    await probe.waitUntilStarted()
    caller.cancel()

    let result = await caller.result
    #expect(throws: CancellationError.self) { try result.get() }

    // The operation is cancelled too, not left running until its own deadline.
    while await !probe.observedCancellation {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await probe.observedCancellation)
}

@Test(.timeLimit(.minutes(1)))
func asyncTimeoutAlreadyCancelledCallerThrowsCancellation() async {
    let caller = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await AsyncTimeout.run(timeout: .seconds(600), operation: "pre-cancelled") {
            try await Task.sleep(for: .seconds(600))
            return 1
        }
    }
    let result = await caller.result
    #expect(throws: CancellationError.self) { try result.get() }
}

@Test(.timeLimit(.minutes(1)))
func asyncTimeoutHugeDurationDoesNotTrap() async throws {
    // `seconds * 1_000_000_000` overflows Int64 for these; the deadline must saturate.
    let huge = try await AsyncTimeout.run(timeout: .seconds(Int64.max), operation: "huge-timeout") { 7 }
    #expect(huge == 7)
    let large = try await AsyncTimeout.run(timeout: .seconds(10_000_000_000), operation: "large-timeout") { 8 }
    #expect(large == 8)
}

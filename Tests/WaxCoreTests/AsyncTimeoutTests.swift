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

@Test(.timeLimit(.minutes(5)))
func asyncTimeoutCountsFromWhenTheOperationStarts() async throws {
    // In a busy process the operation's task can wait for a thread longer than the
    // timeout; that wait is not the operation's. The launch stands in for it by starting
    // the task only after the whole timeout has passed since the call.
    let value = try await AsyncTimeout.run(
        timeout: .milliseconds(300),
        operation: "late-start",
        startingWith: { body in
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                await body()
            }
        }
    ) {
        42
    }
    #expect(value == 42)
}

@Test(.timeLimit(.minutes(5)))
func asyncTimeoutBoundsAnOperationThatStartsThenWaitsOnABusyActor() async throws {
    // The operation starts at once, then waits on an actor whose executor is held: the
    // deadline is armed before that hop, so the caller gets control back regardless.
    let actorQueue = DispatchQueue(label: "com.wax.tests.busy-actor")
    let release = DispatchSemaphore(value: 0)
    actorQueue.async { release.wait() }
    let busy = BusyActor(queue: actorQueue)
    defer { release.signal() }

    await #expect(throws: AsyncTimeout.TimeoutError.self) {
        _ = try await AsyncTimeout.run(timeout: .milliseconds(200), operation: "busy-actor") {
            await busy.markReached()
            return 0
        }
    }
    // The bound held while the operation was still stuck behind the actor.
    #expect(!busy.wasReached)
}

/// An actor on its own dispatch queue, so a test can hold its executor without
/// blocking a cooperative thread.
private actor BusyActor {
    private let executor: QueueExecutor
    private let reached = ReachedFlag()

    init(queue: DispatchQueue) {
        executor = QueueExecutor(queue: queue)
    }

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    nonisolated var wasReached: Bool { reached.value }

    func markReached() {
        reached.set()
    }
}

private final class ReachedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var reached = false

    var value: Bool { lock.withLock { reached } }

    func set() { lock.withLock { reached = true } }
}

private final class QueueExecutor: SerialExecutor, @unchecked Sendable {
    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async { unowned.runSynchronously(on: executor) }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}

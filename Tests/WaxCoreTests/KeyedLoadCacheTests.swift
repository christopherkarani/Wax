import Foundation
import Testing
@testable import WaxCore

/// Deadlock guard only: a broken cache never signals, and the test must fail rather than hang.
private func guardDeadline() -> DispatchTime { .now() + .seconds(30) }

private struct LoadFailure: Error, Equatable {}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Test func keyedLoadCacheDoesNotBlockOtherKeysWhileALoadIsInFlight() throws {
    let cache = KeyedLoadCache<String, String>()
    let slowStarted = DispatchSemaphore(value: 0)
    let releaseSlow = DispatchSemaphore(value: 0)
    let slowFinished = DispatchSemaphore(value: 0)
    let fastFinished = DispatchSemaphore(value: 0)

    Thread.detachNewThread {
        _ = try? cache.value(for: "gpu") {
            slowStarted.signal()
            releaseSlow.wait()
            return "gpu-model"
        }
        slowFinished.signal()
    }
    #expect(slowStarted.wait(timeout: guardDeadline()) == .success)

    let fastResult = LockedBox<String?>(nil)
    Thread.detachNewThread {
        fastResult.set(try? cache.value(for: "cpu") { "cpu-model" })
        fastFinished.signal()
    }

    // The slow "gpu" load is still blocked here, so a "cpu" load that completes proves
    // the cache does not hold one lock across every load.
    let fastCompleted = fastFinished.wait(timeout: guardDeadline()) == .success
    releaseSlow.signal()
    #expect(slowFinished.wait(timeout: guardDeadline()) == .success)
    if !fastCompleted { _ = fastFinished.wait(timeout: guardDeadline()) }

    #expect(fastCompleted, "a load for another key waited behind the in-flight load")
    #expect(fastResult.get() == "cpu-model")
    #expect(try cache.value(for: "gpu") { "reloaded" } == "gpu-model")
}

@Test func keyedLoadCacheLoadsEachKeyOnceForConcurrentCallers() throws {
    let cache = KeyedLoadCache<String, Int>()
    let loads = Counter()
    let loadStarted = DispatchSemaphore(value: 0)
    let releaseLoad = DispatchSemaphore(value: 0)
    let callers = 4
    let finished = DispatchSemaphore(value: 0)
    let results = LockedBox<[Int]>([])

    for _ in 0..<callers {
        Thread.detachNewThread {
            let value = try? cache.value(for: "model") {
                loads.increment()
                loadStarted.signal()
                releaseLoad.wait()
                return 7
            }
            results.update { $0.append(value ?? -1) }
            finished.signal()
        }
    }
    #expect(loadStarted.wait(timeout: guardDeadline()) == .success)
    // One release per caller, so a cache that starts duplicate loads fails on the count
    // instead of leaving the extra loaders blocked.
    for _ in 0..<callers { releaseLoad.signal() }
    for _ in 0..<callers {
        #expect(finished.wait(timeout: guardDeadline()) == .success)
    }

    #expect(loads.value == 1)
    #expect(results.get() == Array(repeating: 7, count: callers))
}

@Test func keyedLoadCacheDoesNotCacheFailures() throws {
    let cache = KeyedLoadCache<String, Int>()
    #expect(throws: LoadFailure.self) {
        try cache.value(for: "model") { throw LoadFailure() }
    }
    #expect(try cache.value(for: "model") { 3 } == 3)
    #expect(try cache.value(for: "model") { 4 } == 3)
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
    func get() -> Value { lock.withLock { value } }
}

#if MCPServer
import Foundation
import Testing
@testable import wax_mcp

/// A `roots/list` request that never returns until the test releases it, the
/// way an SDK request to a client that never answers stays parked.
private final class UnansweredRootsRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private let lateAnswer: [String]?

    init(lateAnswer: [String]? = nil) {
        self.lateAnswer = lateAnswer
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func request() async -> [String]? {
        await withCheckedContinuation { continuation in
            park(continuation)
        }
        return lateAnswer
    }

    func release() {
        lock.lock()
        let waiting = parked
        parked = []
        released = true
        lock.unlock()
        waiting.forEach { $0.resume() }
    }

    private func park(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        calls += 1
        if released {
            lock.unlock()
            continuation.resume()
            return
        }
        parked.append(continuation)
        lock.unlock()
    }
}

private final class CountingRootsRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let answer: [String]?

    init(answer: [String]?) {
        self.answer = answer
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func request() async -> [String]? {
        record()
        return answer
    }

    private func record() {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
    }
}

@Test
func unansweredRootsRefreshIsSingleFlightAndBacksOff() async {
    let client = UnansweredRootsRequest()
    defer { client.release() }
    let gate = MCPRootsFetchGate(timeout: .milliseconds(200), backoff: .seconds(30))

    let first = await gate.fetch { await client.request() }
    #expect(first.isEmpty)

    let clock = ContinuousClock()
    let start = clock.now
    for _ in 0..<10 {
        let roots = await gate.fetch { await client.request() }
        #expect(roots.isEmpty)
    }
    #expect(clock.now - start < .milliseconds(150))
    #expect(client.callCount == 1)
}

@Test
func concurrentRootsRefreshesJoinOneRequest() async {
    let client = UnansweredRootsRequest()
    defer { client.release() }
    let gate = MCPRootsFetchGate(timeout: .milliseconds(200), backoff: .seconds(30))

    await withTaskGroup(of: [String].self) { group in
        for _ in 0..<8 {
            group.addTask { await gate.fetch { await client.request() } }
        }
        for await roots in group {
            #expect(roots.isEmpty)
        }
    }
    #expect(client.callCount == 1)
}

@Test
func expiredBackoffJoinsTheStillParkedRequest() async throws {
    let client = UnansweredRootsRequest()
    defer { client.release() }
    let gate = MCPRootsFetchGate(timeout: .milliseconds(50), backoff: .milliseconds(100))

    _ = await gate.fetch { await client.request() }
    try await Task.sleep(for: .milliseconds(150))
    _ = await gate.fetch { await client.request() }
    #expect(client.callCount == 1)
}

@Test
func failedRootsRequestBacksOff() async {
    let client = CountingRootsRequest(answer: nil)
    let gate = MCPRootsFetchGate(timeout: .seconds(2), backoff: .seconds(30))

    _ = await gate.fetch { await client.request() }
    _ = await gate.fetch { await client.request() }
    #expect(client.callCount == 1)
}

@Test
func answeredRootsRequestsAreNotBackedOff() async {
    let empty = CountingRootsRequest(answer: [])
    let gate = MCPRootsFetchGate(timeout: .seconds(2), backoff: .seconds(30))
    _ = await gate.fetch { await empty.request() }
    _ = await gate.fetch { await empty.request() }
    #expect(empty.callCount == 2)

    let rooted = CountingRootsRequest(answer: ["/tmp/project"])
    let roots = await gate.fetch { await rooted.request() }
    #expect(roots == ["/tmp/project"])
}

@Test
func lateRootsAnswerClearsTheBackoff() async throws {
    let client = UnansweredRootsRequest(lateAnswer: ["/tmp/late"])
    let gate = MCPRootsFetchGate(timeout: .milliseconds(50), backoff: .seconds(30))

    _ = await gate.fetch { await client.request() }
    client.release()
    try await Task.sleep(for: .milliseconds(100))

    let answered = CountingRootsRequest(answer: ["/tmp/project"])
    let roots = await gate.fetch { await answered.request() }
    #expect(answered.callCount == 1)
    #expect(roots == ["/tmp/project"])
}
#endif

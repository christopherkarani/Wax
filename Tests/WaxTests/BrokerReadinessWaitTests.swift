import Foundation
import Testing
@testable import Wax

private actor ReadinessTestGate {
    private var open = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    /// True once the watchdog fired. A text result that arrives while this
    /// is false provably did not wait on provider readiness — no wall clock
    /// needed, so loaded CI runners cannot flake it.
    func wasReleased() -> Bool { released }
}

private enum ReadinessTestError: Error { case unavailable }

private func withBlockedReadiness(
    _ body: (AgentBrokerService, ReadinessTestGate) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-readiness-wait-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = ReadinessTestGate()
    let service = try await AgentBrokerService(
        storePath: root.appendingPathComponent("memory.wax").path,
        sessionRootPath: root.appendingPathComponent("sessions").path,
        noEmbedder: false,
        embedderChoice: "auto",
        requireVector: false,
        readiness: EmbeddingReadiness()
    ) {
        await gate.wait()
        throw ReadinessTestError.unavailable
    }
    // Bound failures even against the old cancellation-insensitive waiter.
    // Ten seconds keeps failure-mode runs fast while staying an order of
    // magnitude beyond CI noise for the non-waiting paths under test.
    let watchdog = Task {
        try? await Task.sleep(for: .seconds(10))
        await gate.release()
    }
    do {
        try await body(service, gate)
        watchdog.cancel()
        await watchdog.value
        try await service.close()
    } catch {
        watchdog.cancel()
        await watchdog.value
        try? await service.close()
        throw error
    }
}

@Suite("BrokerReadinessWaitTests")
struct BrokerReadinessWaitTests {
    @Test(arguments: ["search", "recall"])
    func textRetrievalDoesNotWaitForBlockedProvider(command: String) async throws {
        try await withBlockedReadiness { service, gate in
            let opened = await service.handle(.init(command: "session_open", arguments: [
                "project": .string("readiness-tests"),
            ]))
            let sessionID = try #require(opened.payload?.objectValue?["session_id"]?.stringValue)
            let result = await service.handle(.init(command: command, arguments: [
                "query": .string("available text"),
                "mode": .string("text"),
                "session_id": .string(sessionID),
            ]))
            #expect(result.ok)
            // Deterministic non-waiting proof: a result that arrives before
            // the watchdog fired cannot have waited on provider readiness.
            // (A wall-clock bound here flaked on loaded CI runners where even
            // warmed text queries exceed one second.)
            #expect(await gate.wasReleased() == false)
        }
    }

    @Test(arguments: [false, true])
    func blockedReadinessWaitReturnsOnTimeoutOrCancellation(cancel: Bool) async throws {
        try await withBlockedReadiness { service, _ in
            let memory = await service.longTermMemory
            // Warm the readiness-wait machinery outside the measured section
            // so the bound guards timeout/cancellation promptness, not first-
            // use task spin-up on loaded runners.
            _ = await Task {
                try await AgentBrokerService.awaitRememberReady(
                    memory: memory,
                    timeout: .milliseconds(20)
                )
            }.result
            let start = ContinuousClock.now
            let waiter = Task {
                try await AgentBrokerService.awaitRememberReady(
                    memory: memory,
                    timeout: cancel ? .seconds(30) : .milliseconds(20)
                )
            }
            if cancel { waiter.cancel() }
            let result = await waiter.result
            switch result {
            case .success:
                Issue.record("Blocked readiness unexpectedly succeeded")
            case .failure(let error):
                if cancel {
                    #expect(error is CancellationError)
                } else {
                    #expect(error.localizedDescription.contains("did not become ready"))
                }
            }
            // Hang backstop only: correctness is pinned by the error-identity
            // assertions above (plus the watchdog, which turns a
            // timeout-ignoring regression into a deterministic "unexpectedly
            // succeeded" failure). A tight promptness bound flaked on loaded
            // CI runners; ten seconds still fails a true hang fast.
            #expect(start.duration(to: .now) < .seconds(10))
            #expect(await memory.shouldDeferRememberUntilEmbedderReady())
        }
    }
}

import Foundation
import Testing
@testable import Wax

private actor ReadinessTestGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private enum ReadinessTestError: Error { case unavailable }

private func withBlockedReadiness(
    _ body: (AgentBrokerService) async throws -> Void
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
    let watchdog = Task {
        try? await Task.sleep(for: .seconds(2))
        await gate.release()
    }
    do {
        try await body(service)
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
        try await withBlockedReadiness { service in
            let opened = await service.handle(.init(command: "session_open", arguments: [
                "project": .string("readiness-tests"),
            ]))
            let sessionID = try #require(opened.payload?.objectValue?["session_id"]?.stringValue)
            let start = ContinuousClock.now
            let result = await service.handle(.init(command: command, arguments: [
                "query": .string("available text"),
                "mode": .string("text"),
                "session_id": .string(sessionID),
            ]))
            #expect(result.ok)
            #expect(start.duration(to: .now) < .seconds(1))
        }
    }

    @Test(arguments: [false, true])
    func blockedReadinessWaitReturnsOnTimeoutOrCancellation(cancel: Bool) async throws {
        try await withBlockedReadiness { service in
            let memory = await service.longTermMemory
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
            #expect(start.duration(to: .now) < .seconds(1))
            #expect(await memory.shouldDeferRememberUntilEmbedderReady())
        }
    }
}

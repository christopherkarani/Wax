import Foundation
import Testing
@testable import Wax

private actor BackfillProviderGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var started = false

    func wait() async {
        started = true
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private struct BlockedBackfillEmbedder: EmbeddingProvider {
    let dimensions = 2
    let normalize = true
    let identity: EmbeddingIdentity? = nil
    let gate: BackfillProviderGate

    func embed(_ text: String) async throws -> [Float] {
        await gate.wait()
        return [1, 0]
    }
}

private struct BackfillSemanticEmbedder: EmbeddingProvider {
    let dimensions = 2
    let normalize = true
    let identity: EmbeddingIdentity? = .init(
        provider: "backfill-test", model: "semantic", dimensions: 2, normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        text.contains("bicycle") || text.contains("cycling") ? [1, 0] : [0, 1]
    }
}

@Suite("BrokerAutomaticBackfillTests")
struct BrokerAutomaticBackfillTests {
    @Test(arguments: [false, true])
    func mergedSearchDoesNotHideEitherStoresFallback(workingDegraded: Bool) {
        let active = MemoryOrchestrator.SearchExecution(
            hits: [], requestedMode: .hybrid(), effectiveMode: .hybrid(), queryEmbeddingState: .available
        )
        let degraded = MemoryOrchestrator.SearchExecution(
            hits: [], requestedMode: .hybrid(), effectiveMode: .textOnly, queryEmbeddingState: .timeout
        )
        let result = AgentBrokerService.mergeSearchExecutions(
            working: workingDegraded ? degraded : active,
            durable: workingDegraded ? active : degraded,
            topK: 3
        )
        #expect(result.effectiveMode == .textOnly)
        #expect(result.queryEmbeddingState == .timeout)
    }

    @Test
    func partialVectorFailureIsVisibleWithoutClaimingTheEmbedderIsMissing() {
        let mixed = AgentBrokerService.retrievalDowngradeWarning(
            requestedMode: "hybrid(alpha=0.500)", effectiveMode: "mixed", queryEmbeddingState: "mixed"
        )
        #expect(mixed?.contains("some memory stores") == true)
        let timedOut = AgentBrokerService.retrievalDowngradeWarning(
            requestedMode: "hybrid(alpha=0.500)", effectiveMode: "text", queryEmbeddingState: "available"
        )
        #expect(timedOut?.contains("vector search") == true)
        #expect(timedOut?.contains("embedder missing") == false)
    }

    @Test
    func closingDuringUncooperativeInferencePreservesTextAndDoesNotWaitForModel() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-close-backfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("memory.wax").path
        let sessions = root.appendingPathComponent("sessions").path
        let seed = try await AgentBrokerService(
            storePath: store, sessionRootPath: sessions,
            noEmbedder: true, embedderChoice: "auto", requireVector: false
        )
        let written = await seed.handle(.init(command: "remember", arguments: [
            "content": .string("The bicycle is safe in the garage."),
        ]))
        #expect(written.ok)
        try await seed.close()

        let gate = BackfillProviderGate()
        let broker = try await AgentBrokerService(
            storePath: store, sessionRootPath: sessions,
            noEmbedder: false, embedderChoice: "auto", requireVector: false,
            embedderOverride: BlockedBackfillEmbedder(gate: gate)
        )
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(3))
            await gate.release()
        }
        defer { watchdog.cancel() }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while !(await gate.started), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await gate.started)
            let start = ContinuousClock.now
            try await broker.close()
            #expect(start.duration(to: .now) < .seconds(1))
            await gate.release()

            let reopened = try await AgentBrokerService(
                storePath: store, sessionRootPath: sessions,
                noEmbedder: true, embedderChoice: "auto", requireVector: false
            )
            let memory = await reopened.longTermMemory
            let stats = await memory.runtimeStats()
            #expect(stats.framesWithoutVectors == 1)
            let hits = try await memory.search(query: "bicycle", mode: .textOnly)
            #expect(hits.first?.previewText?.contains("bicycle") == true)
            try await reopened.close()
        } catch {
            await gate.release()
            try? await broker.close()
            throw error
        }
    }

    @Test(arguments: [false, true])
    func readyProviderRepairsDurableAndResumedWorkingStores(afterWaitTimeout: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-auto-backfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("memory.wax").path
        let sessions = root.appendingPathComponent("sessions").path
        let seed = try await AgentBrokerService(
            storePath: store, sessionRootPath: sessions,
            noEmbedder: true, embedderChoice: "auto", requireVector: false
        )
        let sessionID: String
        do {
            let opened = await seed.handle(.init(command: "session_open", arguments: [
                "project": .string("backfill-project"),
                "agent_id": .string("backfill-agent"),
                "run_id": .string("backfill-run"),
            ]))
            sessionID = try #require(opened.payload?.objectValue?["session_id"]?.stringValue)
            for type in ["fact", "task_state"] {
                let written = await seed.handle(.init(command: "remember", arguments: [
                    "session_id": .string(sessionID),
                    "memory_type": .string(type),
                    "content": .string("The bicycle is stored in the \(type) garage."),
                ]))
                #expect(written.ok)
            }
            try await seed.close()
        } catch {
            try? await seed.close()
            throw error
        }

        let gate = BackfillProviderGate()
        if !afterWaitTimeout { await gate.release() }
        let broker = try await AgentBrokerService(
            storePath: store, sessionRootPath: sessions,
            noEmbedder: false, embedderChoice: "auto", requireVector: false,
            readiness: EmbeddingReadiness(),
            factoryOverride: {
                await gate.wait()
                return BackfillSemanticEmbedder()
            }
        )
        do {
            // Opening the historical working lane must not wait on model loading.
            let resumed = await broker.handle(.init(command: "session_open", arguments: [
                "session_id": .string(sessionID),
            ]))
            #expect(resumed.ok)
            let durable = await broker.longTermMemory
            if afterWaitTimeout {
                do {
                    try await AgentBrokerService.awaitRememberReady(memory: durable, timeout: .milliseconds(20))
                    Issue.record("Expected the blocked provider wait to time out")
                } catch {
                    #expect(error.localizedDescription.contains("did not become ready"))
                }
                await gate.release()
            }
            let uuid = try #require(UUID(uuidString: sessionID))
            let working = try #require(await broker.activeSessions[uuid]?.memory)
            for memory in [durable, working] {
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while ContinuousClock.now < deadline {
                    let stats = await memory.runtimeStats()
                    if stats.queryEmbedderReady && stats.framesWithoutVectors == 0 { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let stats = await memory.runtimeStats()
                #expect(stats.framesWithoutVectors == 0)
                let result = try await memory.searchExecution(
                    query: "cycling", mode: .vectorOnly, topK: 1
                )
                #expect(result.hits.first?.previewText?.contains("bicycle") == true)
                #expect(result.hits.first?.sources.contains(.vector) == true)
            }
            try await broker.close()
        } catch {
            await gate.release()
            try? await broker.close()
            throw error
        }
    }
}

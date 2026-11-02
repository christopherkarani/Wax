import Foundation
import Testing
@testable import Wax

private actor BackfillProviderGate {
    private(set) var released = false
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
    func mergeSearchExecutionsDoesNotHideEitherStoresFallback(workingDegraded: Bool) {
        let active = MemoryOrchestrator.SearchExecution(
            hits: [],
            diagnostics: .vector(requested: .hybrid(), effective: .hybrid())
        )
        let degraded = MemoryOrchestrator.SearchExecution(
            hits: [],
            diagnostics: .text(requested: .hybrid(), embedding: .timeout)
        )
        let result = BrokerRecall.mergeSearchExecutions(
            working: workingDegraded ? degraded : active,
            durable: workingDegraded ? active : degraded,
            topK: 3
        )
        #expect(result.effectiveMode == .textOnly)
        #expect(result.queryEmbeddingState == .timeout)
    }

    @Test
    func mergeSearchExecutionsPrefersWorkingOverDurableOnEqualScores() {
        let working = MemoryOrchestrator.MemorySearchHit(
            frameId: 1,
            score: 0.42,
            previewText: "working-note",
            sources: [.text]
        )
        let durable = MemoryOrchestrator.MemorySearchHit(
            frameId: 99,
            score: 0.42,
            previewText: "durable-note",
            sources: [.text]
        )
        let strongerDurable = MemoryOrchestrator.MemorySearchHit(
            frameId: 7,
            score: 0.91,
            previewText: "strong-durable",
            sources: [.text]
        )
        let result = BrokerRecall.mergeSearchExecutions(
            working: MemoryOrchestrator.SearchExecution(
                hits: [working],
                diagnostics: .text(requested: .textOnly, embedding: .notRequested)
            ),
            durable: MemoryOrchestrator.SearchExecution(
                hits: [strongerDurable, durable],
                diagnostics: .text(requested: .textOnly, embedding: .notRequested)
            ),
            topK: 3
        )
        #expect(result.hits.map(\.previewText) == ["strong-durable", "working-note", "durable-note"])
    }

    @Test
    func partialVectorFailureIsVisibleWithoutClaimingTheEmbedderIsMissing() {
        let mixed = AgentBrokerService.retrievalDowngradeWarning(
            .mixed(requested: .hybrid(alpha: 0.5))
        )
        #expect(mixed?.contains("some memory stores") == true)
        let timedOut = AgentBrokerService.retrievalDowngradeWarning(
            RAGContext.Diagnostics.text(requested: .hybrid(), embedding: .available)
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
        // Hang backstop only. The gate is otherwise released solely by this
        // test *after* close() returns, so a close() that waits for the blocked
        // backfill can only finish once the watchdog fires — which the
        // `released == false` assertion below turns into a deterministic
        // failure instead of a wall-clock race under `--parallel`.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(30))
            await gate.release()
        }
        defer { watchdog.cancel() }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !(await gate.started), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await gate.started)
            try await broker.close()
            #expect(
                await gate.released == false,
                "close() waited for the blocked backfill instead of abandoning it"
            )
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

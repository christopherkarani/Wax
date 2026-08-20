import Foundation
import Testing

#if MCPServer
@testable import wax_mcp
@testable import Wax
@testable import WaxCore

/// Phase 0 contracts from Resources/docs/wax-mcp-reliability-plan.md (T0.1–T0.6).
private func withReliabilityBroker<T>(
    _ body: (AgentBrokerService, URL) async throws -> T
) async throws -> T {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-reliability-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let service = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false
    )
    do {
        let result = try await body(service, sessionRootURL)
        try await service.close()
        return result
    } catch {
        try? await service.close()
        throw error
    }
}

private func requireObject(_ value: AgentBrokerValue?) throws -> [String: AgentBrokerValue] {
    try #require(value?.objectValue)
}

private func requireString(_ object: [String: AgentBrokerValue], _ key: String) throws -> String {
    try #require(object[key]?.stringValue)
}

private func resultTexts(_ payload: [String: AgentBrokerValue]) -> [String] {
    payload["results"]?.arrayValue?.compactMap { result in
        result.objectValue?["text"]?.stringValue
    } ?? []
}

@Test
func t01DefaultRecallHardFiltersForeignAndUnlabeledFrames() async throws {
    try await withReliabilityBroker { service, _ in
        let started = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("t01-agent"),
                "run_id": .string("t01-run"),
                "cwd": .string("/tmp"),
            ]
        ))
        #expect(started.ok == true)
        let sessionID = try requireString(try requireObject(started.payload), "session_id")

        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("PROJECT-A-TOKEN unique decision for AlphaRepo Swarm PR."),
                "memory_type": .string("decision"),
                "durability": .string("durable"),
                "project": .string("AlphaRepo"),
            ]
        ))).ok == true)

        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("PROJECT-B-TOKEN foreign BetaRepo contamination frame."),
                "memory_type": .string("decision"),
                "durability": .string("durable"),
                "project": .string("BetaRepo"),
            ]
        ))).ok == true)

        // Historical/unlabeled frame: write past broker inference so wax.project is absent (C3).
        try await service.longTermMemory.remember(
            "UNLABELED-TOKEN frame with no project metadata at all.",
            metadata: [
                MemoryMetadataKeys.type: MemoryType.decision.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.durable.rawValue,
            ]
        )
        try await service.longTermMemory.flush()

        let defaultRecall = await service.handle(.init(
            command: "recall",
            arguments: [
                "query": .string("PROJECT-A-TOKEN Swarm PR AlphaRepo"),
                "session_id": .string(sessionID),
                "project": .string("AlphaRepo"),
                "mode": .string("text"),
                "limit": .int(12),
            ]
        ))
        #expect(defaultRecall.ok == true, "recall failed: \(defaultRecall.error ?? "nil")")
        let defaultPayload = try requireObject(defaultRecall.payload)
        let defaultTexts = resultTexts(defaultPayload)
        #expect(defaultTexts.contains { $0.contains("PROJECT-A-TOKEN") })
        #expect(!defaultTexts.contains { $0.contains("PROJECT-B-TOKEN") })
        #expect(!defaultTexts.contains { $0.contains("UNLABELED-TOKEN") })
        #expect(defaultPayload["project_miss"]?.boolValue == false)

        let globalForeign = await service.handle(.init(
            command: "recall",
            arguments: [
                "query": .string("PROJECT-B-TOKEN foreign BetaRepo"),
                "scope": .string("global"),
                "mode": .string("text"),
                "limit": .int(12),
            ]
        ))
        #expect(globalForeign.ok == true)
        #expect(resultTexts(try requireObject(globalForeign.payload)).contains { $0.contains("PROJECT-B-TOKEN") })

        let globalUnlabeled = await service.handle(.init(
            command: "recall",
            arguments: [
                "query": .string("UNLABELED-TOKEN frame with no project"),
                "scope": .string("global"),
                "mode": .string("text"),
                "limit": .int(12),
            ]
        ))
        #expect(globalUnlabeled.ok == true)
        #expect(resultTexts(try requireObject(globalUnlabeled.payload)).contains { $0.contains("UNLABELED-TOKEN") })
    }
}

@Test
func t01EmptyProjectLaneDoesNotAutoWidenToGlobal() async throws {
    try await withReliabilityBroker { service, _ in
        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("ONLY-OTHER-PROJECT-TOKEN lives in OtherLand."),
                "memory_type": .string("decision"),
                "durability": .string("durable"),
                "project": .string("OtherLand"),
            ]
        ))).ok == true)

        let miss = await service.handle(.init(
            command: "recall",
            arguments: [
                "query": .string("ONLY-OTHER-PROJECT-TOKEN"),
                "project": .string("MissingLand"),
                "mode": .string("text"),
                "limit": .int(8),
            ]
        ))
        #expect(miss.ok == true)
        let payload = try requireObject(miss.payload)
        #expect(payload["project_miss"]?.boolValue == true)
        #expect(resultTexts(payload).isEmpty)
        let message = payload["scope_miss_message"]?.stringValue ?? ""
        #expect(message.contains("no frames for project MissingLand"))
        #expect(!message.lowercased().contains("showing global"))
    }
}

@Test
func t02HandoffLatestHitAppearsInDefaultProjectRecall() async throws {
    try await withReliabilityBroker { service, _ in
        let token = "HANDOFF-X-\(UUID().uuidString.prefix(8))"
        let handoff = await service.handle(.init(
            command: "handoff",
            arguments: [
                "content": .string("\(token) ToolCallExecutor Swarm cut ready for CI watch."),
                "project": .string("SwarmX"),
            ]
        ))
        #expect(handoff.ok == true)

        let latest = await service.handle(.init(
            command: "handoff_latest",
            arguments: ["project": .string("SwarmX")]
        ))
        #expect(latest.ok == true)
        let latestPayload = try requireObject(latest.payload)
        #expect(latestPayload["found"]?.boolValue == true)
        #expect((latestPayload["content"]?.stringValue ?? "").contains(token))

        let recall = await service.handle(.init(
            command: "recall",
            arguments: [
                "query": .string("\(token) ToolCallExecutor Swarm"),
                "project": .string("SwarmX"),
                "mode": .string("text"),
                "limit": .int(8),
            ]
        ))
        #expect(recall.ok == true, "recall failed: \(recall.error ?? "nil")")
        let texts = resultTexts(try requireObject(recall.payload))
        #expect(texts.contains { $0.contains(token) })
    }
}

@Test
func t03RememberRebindsActiveSessionUUIDAcrossBrokerHop() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-hop-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let first = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false
    )
    let started = await first.handle(.init(
        command: "session_start",
        arguments: [
            "agent_id": .string("hop-agent"),
            "run_id": .string("hop-run"),
        ]
    ))
    #expect(started.ok == true)
    let sessionID = try requireString(try requireObject(started.payload), "session_id")
    // Drop in-process live map without ending the manifest (broker hop).
    try await first.close()

    let second = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false
    )
    defer { Task { try? await second.close() } }

    let remembered = await second.handle(.init(
        command: "remember",
        arguments: [
            "content": .string("Rebind after hop must land on the same session UUID."),
            "session_id": .string(sessionID),
            "memory_type": .string("task_state"),
            "durability": .string("working"),
        ]
    ))
    #expect(remembered.ok == true, "remember after hop failed: \(remembered.error ?? "nil")")
    #expect(try requireObject(remembered.payload)["framesAdded"]?.intValue ?? 0 >= 1)

    // C4: agent_id+run_id alone must not steal a different UUID on this path —
    // session_start reuse is separate; ensure remember without the UUID still fails closed.
    let missing = await second.handle(.init(
        command: "remember",
        arguments: [
            "content": .string("no session id"),
            "session_id": .string(UUID().uuidString),
        ]
    ))
    #expect(missing.ok == false)
    let err = missing.error ?? ""
    #expect(err.contains("resumable=false") || err.contains("not active") || err.contains("unknown"))
}

@Test
func t04SessionEndSummaryDistinguishesThisSessionFromSiblings() async throws {
    try await withReliabilityBroker { service, _ in
        let firstID = try requireString(try requireObject((await service.handle(.init(
            command: "session_start",
            arguments: ["agent_id": .string("t04-a"), "run_id": .string("t04-a")]
        ))).payload), "session_id")
        let secondID = try requireString(try requireObject((await service.handle(.init(
            command: "session_start",
            arguments: ["agent_id": .string("t04-b"), "run_id": .string("t04-b")]
        ))).payload), "session_id")
        #expect(firstID != secondID)

        let ended = await service.handle(.init(
            command: "session_end",
            arguments: ["session_id": .string(firstID)]
        ))
        #expect(ended.ok == true)
        let payload = try requireObject(ended.payload)
        #expect(payload["active"]?.boolValue == false)
        #expect(payload["ended"]?.boolValue == true)
        #expect(payload["remaining_active"]?.boolValue == true)
        let display = payload["display_text"]?.stringValue ?? ""
        #expect(display.lowercased().contains("active=false") || display.lowercased().contains("this session"))
        #expect(display.contains("remaining_active") || display.lowercased().contains("other"))

        // Concurrent-style close: session_close after end is idempotent.
        let closed = await service.handle(.init(
            command: "session_close",
            arguments: [
                "session_id": .string(firstID),
                "content": .string("idempotent close after end"),
                "project": .string("Wax"),
            ]
        ))
        #expect(closed.ok == true, "session_close failed: \(closed.error ?? "nil")")
        let closePayload = try requireObject(closed.payload)
        #expect(closePayload["active"]?.boolValue == false)
    }
}

@Test
func t05RememberNeverReturnsSuccessShapedPendingZero() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-t05-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let gate = ReliabilityEmbedderGate()
    let readiness = EmbeddingReadiness()
    let service = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: false,
        embedderChoice: "auto",
        requireVector: false,
        readiness: readiness
    ) {
        await gate.wait()
        return ReliabilityPendingEmbedder()
    }
    defer { Task { try? await service.close() } }

    async let rememberTask = service.handle(.init(
        command: "remember",
        arguments: ["content": .string("T05 must block until searchable or fail closed.")]
    ))
    try await Task.sleep(for: .milliseconds(80))
    await gate.open()
    let remembered = await rememberTask
    #expect(remembered.ok == true, "remember failed: \(remembered.error ?? "nil")")
    let payload = try requireObject(remembered.payload)
    #expect(payload["status"]?.stringValue != "pending")
    #expect(payload["framesAdded"]?.intValue ?? 0 >= 1)
}

private struct ReliabilityPendingEmbedder: EmbeddingProvider {
    let dimensions = 8
    let normalize = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Test",
        model: "ReliabilityPending",
        dimensions: 8,
        normalized: true
    )
    var executionMode: ProviderExecutionMode { .onDeviceOnly }

    func embed(_ text: String) async throws -> [Float] {
        var vector = [Float](repeating: 0, count: dimensions)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        vector[0] = Float(hash % 1_000) / 1_000
        return vector
    }
}

private actor ReliabilityEmbedderGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

@Test
func t06WorktreeCwdStampsMainRepoNameNotWorktreeFolder() async throws {
    try await withReliabilityBroker { service, _ in
        let mainName = "MainRepo-\(UUID().uuidString.prefix(6))"
        let worktreeFolder = "worktree-clear-forest-\(UUID().uuidString.prefix(6))"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-t06-\(UUID().uuidString)", isDirectory: true)
        let repoURL = root.appendingPathComponent(mainName, isDirectory: true)
        let worktreeURL = root.appendingPathComponent(worktreeFolder, isDirectory: true)
        let worktreeGitDir = repoURL
            .appendingPathComponent(".git/worktrees/\(worktreeFolder)", isDirectory: true)
        try FileManager.default.createDirectory(at: worktreeGitDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktreeURL, withIntermediateDirectories: true)
        try "gitdir: \(worktreeGitDir.path)\n"
            .write(to: worktreeURL.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let started = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("t06-agent"),
                "run_id": .string("t06-run"),
                "cwd": .string(worktreeURL.path),
            ]
        ))
        #expect(started.ok == true)
        let payload = try requireObject(started.payload)
        #expect(payload["project"]?.stringValue == mainName)
        #expect(payload["repo"]?.stringValue == mainName)
        #expect(payload["project"]?.stringValue != worktreeFolder)
    }
}
#endif

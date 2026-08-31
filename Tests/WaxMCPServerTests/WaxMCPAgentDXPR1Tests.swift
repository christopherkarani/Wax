#if MCPServer
import Foundation
import Testing
import MCP
@testable import Wax
@testable import wax_mcp

// MARK: - First-call hybrid wait + loud downgrade

@Test
func hybridRecallWaitsForLoadingEmbedderThenUsesHybrid() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-dx-wait-hybrid-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)

    do {
        var seedConfig = OrchestratorConfig.default
        seedConfig.enableVectorSearch = false
        let seeder = try await AgentBrokerService(
            storePath: storeURL.path,
            sessionRootPath: sessionRootURL.path,
            noEmbedder: true,
            embedderChoice: "auto",
            requireVector: false,
            orchestratorConfig: seedConfig
        )
        let remembered = await seeder.handle(.init(
            command: "remember",
            arguments: ["content": .string("HYBRID_WAIT_NEEDLE Swift actors structured concurrency")]
        ))
        #expect(remembered.ok == true)
        try await seeder.close()
    }

    let gate = DXGate()
    let readiness = EmbeddingReadiness()
    let factory: @Sendable () async throws -> any EmbeddingProvider = {
        await gate.wait()
        return DXDeterministicEmbedder()
    }
    let service = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: false,
        embedderChoice: "minilm",
        requireVector: false,
        readiness: readiness,
        factoryOverride: factory
    )
    defer { Task { try? await service.close() } }

    let loading = try #require((await service.handle(.init(command: "stats"))).payload?.objectValue)
    #expect(loading["embeddingStatus"]?.stringValue == "loading")

    async let recalled = WaxMCPTools.handleCall(
        params: .init(
            name: "recall",
            arguments: [
                "query": "HYBRID_WAIT_NEEDLE",
                "mode": "hybrid",
                "scope": "global",
                "limit": 5,
            ]
        ),
        broker: service
    )
    try await Task.sleep(for: .milliseconds(80))
    #expect(await gate.isClosed)
    await gate.open()

    let result = await recalled
    #expect(result.isError != true)
    let payload = try parseDXJSON(in: result)
    #expect((payload["requested_mode"] as? String)?.hasPrefix("hybrid") == true)
    #expect((payload["effective_mode"] as? String)?.hasPrefix("hybrid") == true)
    #expect((payload["query_embedding_state"] as? String) == "available")
}

@Test
func noEmbedderHybridRecallDoesNotHangAndWarns() async throws {
    try await withDXBroker(noEmbedder: true) { service, _ in
        let started = ContinuousClock.now
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "recall",
                arguments: [
                    "query": "no embedder hybrid should be text",
                    "mode": "hybrid",
                    "scope": "global",
                ]
            ),
            broker: service
        )
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(5))
        #expect(result.isError != true)
        let payload = try parseDXJSON(in: result)
        #expect((payload["effective_mode"] as? String) == "text")
        let warning = try #require(payload["warning"] as? String)
        #expect(warning.contains("hybrid requested"))
        #expect(warning.contains("used text"))
        #expect(payload["query"] != nil)
    }
}

@Test
func vectorOnlyWithoutEmbedderStillThrows() async throws {
    try await withDXBroker(noEmbedder: true) { service, _ in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
                arguments: [
                    "query": "vector only must not remap",
                    "mode": "vector",
                    "topK": 3,
                ]
            ),
            broker: service
        )
        #expect(result.isError == true)
        let text = dxFirstText(in: result).lowercased()
        #expect(text.contains("embedder") || text.contains("vector"))
    }
}

@Test
func retrievalDowngradeWarningMapsEmbeddingStates() {
    #expect(
        AgentBrokerService.retrievalDowngradeWarning(
            requestedMode: "hybrid(alpha=0.500)",
            effectiveMode: "text",
            queryEmbeddingState: "timeout"
        ) == "WARNING: hybrid requested, embedder timeout, used text"
    )
    #expect(
        AgentBrokerService.retrievalDowngradeWarning(
            requestedMode: "hybrid(alpha=0.500)",
            effectiveMode: "text",
            queryEmbeddingState: "circuit_open"
        ) == "WARNING: hybrid requested, embedder circuit open, used text"
    )
    #expect(
        AgentBrokerService.retrievalDowngradeWarning(
            requestedMode: "hybrid(alpha=0.500)",
            effectiveMode: "text",
            queryEmbeddingState: "failed"
        ) == "WARNING: hybrid requested, embedder failed, used text"
    )
    #expect(
        AgentBrokerService.retrievalDowngradeWarning(
            requestedMode: "hybrid(alpha=0.500)",
            effectiveMode: "text",
            queryEmbeddingState: "vector_disabled"
        ) == "WARNING: hybrid requested, vector search disabled, used text"
    )
    #expect(
        AgentBrokerService.retrievalDowngradeWarning(
            requestedMode: "hybrid(alpha=0.500)",
            effectiveMode: "text",
            queryEmbeddingState: "no_embedder"
        ) == "WARNING: hybrid requested, embedder missing, used text"
    )
    #expect(
        AgentBrokerService.retrievalDowngradeWarning(
            requestedMode: "text",
            effectiveMode: "text",
            queryEmbeddingState: "no_embedder"
        ) == nil
    )
    #expect(
        AgentBrokerService.retrievalDowngradeWarning(
            requestedMode: "hybrid(alpha=0.500)",
            effectiveMode: "hybrid(alpha=0.500)",
            queryEmbeddingState: "available"
        ) == nil
    )
}

@Test
func sessionOpenWithoutRecallQueryDoesNotWaitForLoadingEmbedder() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-dx-open-nowait-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)

    let gate = DXGate()
    let readiness = EmbeddingReadiness()
    let factory: @Sendable () async throws -> any EmbeddingProvider = {
        await gate.wait()
        return DXDeterministicEmbedder()
    }
    let service = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: false,
        embedderChoice: "minilm",
        requireVector: false,
        readiness: readiness,
        factoryOverride: factory
    )
    defer {
        Task {
            await gate.open()
            try? await service.close()
        }
    }

    let started = ContinuousClock.now
    let result = await WaxMCPTools.handleCall(
        params: .init(
            name: "session_open",
            arguments: [
                "project": "rv",
                "agent_id": "dx-open-nowait",
                "run_id": "dx-open-nowait-run",
            ]
        ),
        broker: service
    )
    let elapsed = ContinuousClock.now - started
    #expect(elapsed < .seconds(5))
    #expect(result.isError != true)
    let payload = try parseDXJSON(in: result)
    #expect((payload["session_id"] as? String)?.isEmpty == false)
    #expect(payload["recall"] == nil)
    #expect(await gate.isClosed)
}

@Test
func sessionOpenRecallQueryWaitsForLoadingEmbedderThenUsesHybrid() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-dx-open-wait-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)

    let gate = DXGate()
    let readiness = EmbeddingReadiness()
    let factory: @Sendable () async throws -> any EmbeddingProvider = {
        await gate.wait()
        return DXDeterministicEmbedder()
    }
    let service = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: false,
        embedderChoice: "minilm",
        requireVector: false,
        readiness: readiness,
        factoryOverride: factory
    )
    defer {
        Task {
            await gate.open()
            try? await service.close()
        }
    }

    async let opened = WaxMCPTools.handleCall(
        params: .init(
            name: "session_open",
            arguments: [
                "project": "rv",
                "agent_id": "dx-open-wait",
                "run_id": "dx-open-wait-run",
                "recall_query": "session open nested hybrid recall",
            ]
        ),
        broker: service
    )
    try await Task.sleep(for: .milliseconds(80))
    #expect(await gate.isClosed)
    await gate.open()

    let result = await opened
    #expect(result.isError != true)
    let payload = try parseDXJSON(in: result)
    let recall = try #require(payload["recall"] as? [String: Any])
    #expect((recall["requested_mode"] as? String)?.hasPrefix("hybrid") == true)
    #expect((recall["effective_mode"] as? String)?.hasPrefix("hybrid") == true)
    #expect((recall["query_embedding_state"] as? String) == "available")
}

@Test
func sessionOpenRecallQuerySurfacesDowngradeWarningAtTopLevel() async throws {
    try await withDXBroker(noEmbedder: true) { service, _ in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "session_open",
                arguments: [
                    "project": "rv",
                    "agent_id": "dx-open-agent",
                    "run_id": "dx-open-run",
                    "recall_query": "session open nested hybrid recall",
                ]
            ),
            broker: service
        )
        #expect(result.isError != true)
        let payload = try parseDXJSON(in: result)
        let warning = try #require(payload["warning"] as? String)
        #expect(warning.contains("hybrid requested"))
        #expect(warning.contains("used text"))
        let recall = try #require(payload["recall"] as? [String: Any])
        #expect((recall["effective_mode"] as? String) == "text")
        #expect((recall["warning"] as? String)?.contains("hybrid requested") == true)
    }
}

@Test
func compactHybridWarningIsSingleJSONObject() async throws {
    try await withDXBroker(noEmbedder: true) { service, _ in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
                arguments: [
                    "query": "json warning shape",
                    "mode": "hybrid",
                    "topK": 1,
                ]
            ),
            broker: service
        )
        let text = dxFirstText(in: result)
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"))
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        #expect(object is [String: Any])
    }
}

// MARK: - Repo stamp

@Test
func omittedClientCwdWithProjectDoesNotStampProcessRepo() async throws {
    try await withDXBroker(noEmbedder: true) { service, _ in
        let processRepo = MemorySemantics.inferScopeContext().repoName
        let write = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: [
                    "content": "Omitted cwd project rv must not inherit process repo",
                    "project": "rv",
                ]
            ),
            broker: service
        )
        #expect(write.isError != true)

        let search = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
                arguments: [
                    "query": "Omitted cwd project rv must not inherit process repo",
                    "mode": "text",
                    "topK": 5,
                ]
            ),
            broker: service
        )
        #expect(search.isError != true)
        let payload = try parseDXJSON(in: search)
        let results = try #require(payload["results"] as? [Any])
        let hit = try #require(results.first as? [String: Any])
        let metadata = try #require(hit["metadata"] as? [String: Any])
        #expect(metadata["wax.project"] as? String == "rv")
        #expect(metadata["wax.repo"] as? String == "rv")
        if let processRepo, processRepo != "rv" {
            #expect(metadata["wax.repo"] as? String != processRepo)
        }
    }
}

@Test
func omittedClientCwdRecallDoesNotBindProcessProjectIdentity() async throws {
    try await withDXBroker(noEmbedder: true) { service, _ in
        let processRepo = MemorySemantics.inferScopeContext().repoName
        let processProject = MemorySemantics.inferScopeContext().projectName
        let recalled = await WaxMCPTools.handleCall(
            params: .init(
                name: "recall",
                arguments: [
                    "query": "unscoped recall must not inherit process project",
                    "mode": "text",
                    "limit": 5,
                ]
            ),
            broker: service
        )
        #expect(recalled.isError != true)
        let payload = try parseDXJSON(in: recalled)
        #expect(payload["project_miss"] as? Bool == true)
        if let processProject {
            #expect(payload["project"] as? String != processProject)
        }
        if let processRepo {
            #expect(payload["repo"] as? String != processRepo)
        }
        let message = (payload["scope_miss_message"] as? String) ?? ""
        #expect(message.contains("unresolved") || message.contains("no frames for project"))
    }
}

@Test
func waxMCPToolsDoesNotInjectProcessWorkingDirectoryAsCwd() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/WaxMCPServer/WaxMCPTools.swift"),
        encoding: .utf8
    )
    #expect(!source.contains("arguments[\"cwd\"] = .string(FileManager.default.currentDirectoryPath)"))
    #expect(!source.contains("injectClientCWDIfNeeded"))
}

@Test
func recallAndSearchDoNotRepeatEmbedderWaitInsideSerializedHandler() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/Broker/AgentBrokerService.swift"),
        encoding: .utf8
    )
    let recallStart = try #require(source.range(of: "func recall(_ command: BrokerCommand.Recall)"))
    let searchStart = try #require(source.range(of: "func search(_ command: BrokerCommand.Search)"))
    let memorySearchStart = try #require(source.range(of: "func memorySearch(_ command: BrokerCommand.MemorySearch)"))
    let recallBody = source[recallStart.lowerBound..<searchStart.lowerBound]
    let searchBody = source[searchStart.lowerBound..<memorySearchStart.lowerBound]
    #expect(!recallBody.contains("awaitQueryEmbedderIfNeeded"))
    #expect(!searchBody.contains("awaitQueryEmbedderIfNeeded"))
    #expect(source.contains("isQueryEmbedderWaitRequest(request)"))
}

@Test
func agentBrokerClientStartsDaemonWithoutSkipPrewarmWhenEmbedderConfigured() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/Broker/AgentBrokerClient.swift"),
        encoding: .utf8
    )
    let start = try #require(source.range(of: "private static func startBrokerIfNeeded("))
    let end = try #require(source[start.upperBound...].range(of: "process.environment = ProcessInfo.processInfo.environment"))
    let body = source[start.lowerBound..<end.lowerBound]
    #expect(body.contains("daemon"))
    #expect(!body.contains("\"--skip-prewarm\""))
    #expect(body.contains("\"--no-embedder\""))
}

// MARK: - Backfill on prewarm

@Test
func prewarmEmbedderBackfillsUnembeddedFramesOnOpenStore() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-dx-backfill-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)

    do {
        var seedConfig = OrchestratorConfig.default
        seedConfig.enableVectorSearch = false
        let seeder = try await AgentBrokerService(
            storePath: storeURL.path,
            sessionRootPath: sessionRootURL.path,
            noEmbedder: true,
            embedderChoice: "auto",
            requireVector: false,
            orchestratorConfig: seedConfig
        )
        #expect((await seeder.handle(.init(
            command: "remember",
            arguments: ["content": .string("BACKFILL_PREWARM_NEEDLE unique unembedded frame")]
        ))).ok == true)
        try await seeder.close()
    }

    var hybridConfig = OrchestratorConfig.default
    hybridConfig.enableVectorSearch = true
    let service = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: false,
        embedderChoice: "auto",
        requireVector: false,
        embedderOverride: DXDeterministicEmbedder(),
        orchestratorConfig: hybridConfig
    )
    defer { Task { try? await service.close() } }

    let before = try #require((await service.handle(.init(command: "stats"))).payload?.objectValue)
    #expect((before["framesWithoutVectors"]?.intValue ?? 0) > 0)

    await service.prewarmEmbedder()

    let after = try #require((await service.handle(.init(command: "stats"))).payload?.objectValue)
    #expect((after["framesWithoutVectors"]?.intValue ?? 1) == 0)
}

@Test
func noEmbedderPrewarmDoesNotBackfillUnembeddedFrames() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-dx-nobackfill-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)

    var seedConfig = OrchestratorConfig.default
    seedConfig.enableVectorSearch = false
    let service = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false,
        orchestratorConfig: seedConfig
    )
    defer { Task { try? await service.close() } }

    #expect((await service.handle(.init(
        command: "remember",
        arguments: ["content": .string("NO_EMBEDDER_PREWARM stays text only")]
    ))).ok == true)

    let before = try #require((await service.handle(.init(command: "stats"))).payload?.objectValue)
    let beforeMissing = before["framesWithoutVectors"]?.intValue ?? 0

    await service.prewarmEmbedder()

    let after = try #require((await service.handle(.init(command: "stats"))).payload?.objectValue)
    let afterMissing = after["framesWithoutVectors"]?.intValue ?? 0
    #expect(afterMissing == beforeMissing)
    #expect(afterMissing > 0)
}

@Test
func prewarmEmbedderSourceBackfillsAfterSearchWhenEmbedderConfigured() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/Broker/AgentBrokerService.swift"),
        encoding: .utf8
    )
    let start = try #require(source.range(of: "package func prewarmEmbedder() async {"))
    let end = try #require(source[start.upperBound...].range(of: "func flush() async throws"))
    let body = source[start.lowerBound..<end.lowerBound]
    #expect(body.contains("guard !noEmbedder"))
    #expect(body.contains("backfillUnembedded()"))
    let guardRange = try #require(body.range(of: "guard !noEmbedder"))
    let backfillRange = try #require(body.range(of: "backfillUnembedded()"))
    #expect(guardRange.lowerBound < backfillRange.lowerBound)
}

// MARK: - Helpers

private func withDXBroker<T>(
    noEmbedder: Bool,
    _ body: (AgentBrokerService, URL) async throws -> T
) async throws -> T {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-dx-broker-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let service = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: noEmbedder,
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

private func parseDXJSON(in result: CallTool.Result) throws -> [String: Any] {
    let text = dxFirstText(in: result)
    guard let data = text.data(using: .utf8),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(
            domain: "WaxMCPAgentDXPR1Tests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Result is not a JSON object: \(text.prefix(200))"]
        )
    }
    return object
}

private func dxFirstText(in result: CallTool.Result) -> String {
    for content in result.content {
        if case .text(text: let text, annotations: _, _meta: _) = content {
            return text
        }
    }
    return ""
}

private struct DXDeterministicEmbedder: EmbeddingProvider, Sendable {
    let dimensions: Int = 2
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "DXTest",
        model: "Deterministic",
        dimensions: 2,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        let a = Float(text.utf8.count % 97) / 97.0
        let b = Float(text.unicodeScalars.count % 89) / 89.0
        let norm = sqrt(a * a + b * b)
        guard norm > 0 else { return [1, 0] }
        return [a / norm, b / norm]
    }
}

private actor DXGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isClosed: Bool { !opened }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }
}
#endif

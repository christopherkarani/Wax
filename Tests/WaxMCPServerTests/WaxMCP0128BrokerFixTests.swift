#if MCPServer
import Foundation
import MCP
import Testing
@testable import Wax
@testable import wax_mcp

private func withIsolatedBroker<T>(
    _ body: (AgentBrokerService, URL) async throws -> T
) async throws -> T {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-0128-broker-\(UUID().uuidString)", isDirectory: true)
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

private func makeGitRepo(named name: String) throws -> URL {
    let repo = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent(".git", isDirectory: true),
        withIntermediateDirectories: true
    )
    return repo
}

private func requireObject(_ value: AgentBrokerValue?) throws -> [String: AgentBrokerValue] {
    try #require(value?.objectValue)
}

private func requireString(_ object: [String: AgentBrokerValue], _ key: String) throws -> String {
    try #require(object[key]?.stringValue)
}

private struct StatsReasonEmbedder: EmbeddingProvider, Sendable {
    let dimensions: Int = 2
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Test",
        model: "StatsReason",
        dimensions: 2,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        _ = text
        return [1, 0]
    }
}

@Test
func customStorePathDoesNotDefaultToProductSessionRoot() throws {
    let store = FileManager.default.temporaryDirectory
        .appendingPathComponent("iso-\(UUID().uuidString)")
        .appendingPathExtension("wax")
    let resolved = AgentBrokerPathing.resolveSessionRootPath(
        storePath: store.path,
        sessionRootPath: AgentBrokerPathing.defaultSessionRootPath,
        environment: [:]
    )
    let productRoot = AgentBrokerPathing.expandPath(AgentBrokerPathing.defaultSessionRootPath)
    #expect(resolved != productRoot)
    #expect(resolved.contains(".local/share/waxmcp/sessions") == false)
}

@Test
func explicitSessionRootWinsForCustomStore() throws {
    let store = FileManager.default.temporaryDirectory
        .appendingPathComponent("iso-\(UUID().uuidString)")
        .appendingPathExtension("wax")
    let sessionRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("sess-\(UUID().uuidString)", isDirectory: true)
    let resolved = AgentBrokerPathing.resolveSessionRootPath(
        storePath: store.path,
        sessionRootPath: sessionRoot.path,
        environment: [:]
    )
    #expect(resolved == AgentBrokerPathing.expandPath(sessionRoot.path))
}

@Test
func defaultStoreKeepsProductSessionRootUnlessOverridden() throws {
    let productRoot = AgentBrokerPathing.expandPath(AgentBrokerPathing.defaultSessionRootPath)
    let resolved = AgentBrokerPathing.resolveSessionRootPath(
        storePath: AgentBrokerPathing.defaultStorePath,
        sessionRootPath: AgentBrokerPathing.defaultSessionRootPath,
        environment: [:]
    )
    #expect(resolved == productRoot)
}

@Test
func envSessionRootStillOverridesCustomStore() throws {
    let store = FileManager.default.temporaryDirectory
        .appendingPathComponent("iso-\(UUID().uuidString)")
        .appendingPathExtension("wax")
    let envRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("env-sess-\(UUID().uuidString)", isDirectory: true)
    let resolved = AgentBrokerPathing.resolveSessionRootPath(
        storePath: store.path,
        sessionRootPath: AgentBrokerPathing.defaultSessionRootPath,
        environment: ["WAX_SESSION_ROOT_DIR": envRoot.path]
    )
    #expect(resolved == AgentBrokerPathing.expandPath(envRoot.path))
}

@Test
func mcpClientSessionHintIsIsolatedPerInstance() {
    let first = MCPClientSessionHint()
    let second = MCPClientSessionHint()
    first.remember(
        name: "session_start",
        payload: .object(["session_id": .string("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")])
    )
    #expect(first.current() == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
    #expect(second.current() == nil)
}

@Test
func hintedSessionInjectsIntoTaskStateRememberAndRecall() async throws {
    try await withIsolatedBroker { service, _ in
        let hint = MCPClientSessionHint()
        let opened = await WaxMCPTools.handleCall(
            params: .init(
                name: "session_open",
                arguments: [
                    "project": "HintRepo",
                    "agent_id": "hint-agent",
                    "run_id": "hint-run",
                ]
            ),
            broker: service,
            sessionHint: hint
        )
        #expect(opened.isError != true)
        let openPayload = try requireJSONObject(firstTextContent(opened))
        let sessionID = try #require(openPayload["session_id"] as? String)
        #expect(hint.current() == sessionID)

        let remembered = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: [
                    "content": "HINT-TASK-STATE plan locked for inject test",
                    "memory_type": "task_state",
                ]
            ),
            broker: service,
            sessionHint: hint
        )
        #expect(remembered.isError != true)
        let rememberPayload = try requireJSONObject(firstTextContent(remembered))
        #expect(rememberPayload["session_id"] as? String == sessionID)
        #expect(rememberPayload["scope"] as? String == "session")
        #expect(rememberPayload["memory_type"] as? String == "task_state")

        let recalled = await WaxMCPTools.handleCall(
            params: .init(
                name: "recall",
                arguments: [
                    "query": "HINT-TASK-STATE plan locked",
                    "mode": "text",
                    "limit": 5,
                ]
            ),
            broker: service,
            sessionHint: hint
        )
        #expect(recalled.isError != true)
        let recallPayload = try requireJSONObject(firstTextContent(recalled))
        let applied = try #require(recallPayload["applied_filters"] as? [String: Any])
        #expect(applied["session_id"] as? String == sessionID)
        let results = try #require(recallPayload["results"] as? [[String: Any]])
        let recalledText = results.compactMap { $0["text"] as? String }.joined(separator: "\n")
        #expect(recalledText.contains("HINT-TASK-STATE"))
    }
}

@Test
func hintedSessionDoesNotInjectIntoDurableRemember() async throws {
    try await withIsolatedBroker { service, _ in
        let hint = MCPClientSessionHint()
        let opened = await WaxMCPTools.handleCall(
            params: .init(
                name: "session_open",
                arguments: [
                    "project": "HintRepo",
                    "agent_id": "hint-durable",
                    "run_id": "hint-durable-run",
                ]
            ),
            broker: service,
            sessionHint: hint
        )
        #expect(opened.isError != true)
        #expect(hint.current() != nil)

        let remembered = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: [
                    "content": "HINT-DECISION durable must not inherit connection session",
                    "memory_type": "decision",
                ]
            ),
            broker: service,
            sessionHint: hint
        )
        #expect(remembered.isError != true)
        let payload = try requireJSONObject(firstTextContent(remembered))
        #expect(payload["scope"] as? String == "durable")
        #expect(payload["session_id"] == nil || payload["session_id"] is NSNull)
    }
}

@Test
func hintedSessionOpenResumesSameUUIDWithoutConflictingExactPair() async throws {
    try await withIsolatedBroker { service, _ in
        let hint = MCPClientSessionHint()
        let opened = await WaxMCPTools.handleCall(
            params: .init(
                name: "session_open",
                arguments: [
                    "project": "HintOpenRepo",
                    "agent_id": "hint-open-agent",
                    "run_id": "hint-open-run",
                ]
            ),
            broker: service,
            sessionHint: hint
        )
        #expect(opened.isError != true)
        let openPayload = try requireJSONObject(firstTextContent(opened))
        let sessionID = try #require(openPayload["session_id"] as? String)
        #expect(hint.current() == sessionID)

        let resumed = await WaxMCPTools.handleCall(
            params: .init(
                name: "session_open",
                arguments: [
                    "project": "HintOpenRepo",
                ]
            ),
            broker: service,
            sessionHint: hint
        )
        #expect(resumed.isError != true)
        let resumedPayload = try requireJSONObject(firstTextContent(resumed))
        #expect(resumedPayload["session_id"] as? String == sessionID)
        #expect(hint.current() == sessionID)
    }
}

@Test
func hintedSessionOpenDoesNotStealConflictingExactPair() async throws {
    try await withIsolatedBroker { service, _ in
        let hint = MCPClientSessionHint()
        let first = await WaxMCPTools.handleCall(
            params: .init(
                name: "session_open",
                arguments: [
                    "project": "HintOpenRepo",
                    "agent_id": "hint-open-owner",
                    "run_id": "hint-open-owner-run",
                ]
            ),
            broker: service,
            sessionHint: hint
        )
        #expect(first.isError != true)
        let firstID = try #require(try requireJSONObject(firstTextContent(first))["session_id"] as? String)

        let other = await WaxMCPTools.handleCall(
            params: .init(
                name: "session_open",
                arguments: [
                    "project": "HintOpenRepo",
                    "agent_id": "hint-open-other",
                    "run_id": "hint-open-other-run",
                ]
            ),
            broker: service
        )
        #expect(other.isError != true)
        let otherID = try #require(try requireJSONObject(firstTextContent(other))["session_id"] as? String)
        #expect(otherID != firstID)
        #expect(hint.current() == firstID)

        let exact = await WaxMCPTools.handleCall(
            params: .init(
                name: "session_open",
                arguments: [
                    "project": "HintOpenRepo",
                    "agent_id": "hint-open-other",
                    "run_id": "hint-open-other-run",
                ]
            ),
            broker: service,
            sessionHint: hint
        )
        #expect(exact.isError != true)
        let exactPayload = try requireJSONObject(firstTextContent(exact))
        #expect(exactPayload["session_id"] as? String == otherID)
        #expect(exactPayload["session_id"] as? String != firstID)
    }
}

@Test
func hintedSessionInjectsIntoStatsWithoutParrotingUUID() async throws {
    try await withIsolatedBroker { service, _ in
        let hint = MCPClientSessionHint()
        let isolated = MCPClientSessionHint()
        let opened = await WaxMCPTools.handleCall(
            params: .init(
                name: "session_open",
                arguments: [
                    "project": "HintRepo",
                    "agent_id": "hint-stats",
                    "run_id": "hint-stats-run",
                ]
            ),
            broker: service,
            sessionHint: hint
        )
        #expect(opened.isError != true)
        let openPayload = try requireJSONObject(firstTextContent(opened))
        let sessionID = try #require(openPayload["session_id"] as? String)
        #expect(hint.current() == sessionID)
        #expect(isolated.current() == nil)

        let hintedStats = await WaxMCPTools.handleCall(
            params: .init(name: "stats", arguments: [:]),
            broker: service,
            sessionHint: hint
        )
        #expect(hintedStats.isError != true)
        let hintedPayload = try requireJSONObject(firstTextContent(hintedStats))
        let hintedSession = try #require(hintedPayload["session"] as? [String: Any])
        #expect(hintedSession["session_id"] as? String == sessionID)

        let isolatedStats = await WaxMCPTools.handleCall(
            params: .init(name: "stats", arguments: [:]),
            broker: service,
            sessionHint: isolated
        )
        #expect(isolatedStats.isError != true)
        let isolatedPayload = try requireJSONObject(firstTextContent(isolatedStats))
        let isolatedSession = try #require(isolatedPayload["session"] as? [String: Any])
        #expect(isolatedSession["session_id"] == nil || isolatedSession["session_id"] is NSNull)

        let unhintedStats = await WaxMCPTools.handleCall(
            params: .init(name: "stats", arguments: [:]),
            broker: service
        )
        #expect(unhintedStats.isError != true)
        let unhintedPayload = try requireJSONObject(firstTextContent(unhintedStats))
        let unhintedSession = try #require(unhintedPayload["session"] as? [String: Any])
        #expect(unhintedSession["session_id"] == nil || unhintedSession["session_id"] is NSNull)
    }
}

@Test
func unscopedRememberUsesClientCwdNotDaemonScope() async throws {
    let repoB = try makeGitRepo(named: "RepoB")
    defer { try? FileManager.default.removeItem(at: repoB) }

    try await withIsolatedBroker { service, _ in
        let write = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Unscoped durable canary from client cwd RepoB"),
                "cwd": .string(repoB.path),
            ]
        ))
        #expect(write.ok == true)

        let search = await service.handle(.init(
            command: "search",
            arguments: [
                "query": .string("Unscoped durable canary from client cwd"),
                "mode": .string("text"),
                "topK": .int(5),
            ]
        ))
        #expect(search.ok == true)
        let hit = try #require(try requireObject(search.payload)["results"]?.arrayValue?.first?.objectValue)
        let metadata = try #require(hit["metadata"]?.objectValue)
        #expect(metadata["wax.repo"]?.stringValue == repoB.lastPathComponent)
        #expect(metadata["wax.project"]?.stringValue == repoB.lastPathComponent)
    }
}

@Test
func emptyClientCwdDoesNotStampDaemonRepoOnUnscopedRemember() async throws {
    try await withIsolatedBroker { service, _ in
        let write = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Empty client cwd must not inherit daemon repo"),
                "cwd": .string(""),
            ]
        ))
        #expect(write.ok == true)

        let search = await service.handle(.init(
            command: "search",
            arguments: [
                "query": .string("Empty client cwd must not inherit daemon repo"),
                "mode": .string("text"),
                "topK": .int(5),
            ]
        ))
        #expect(search.ok == true)
        let hit = try #require(try requireObject(search.payload)["results"]?.arrayValue?.first?.objectValue)
        let metadata = try #require(hit["metadata"]?.objectValue)
        #expect(metadata["wax.repo"] == nil || metadata["wax.repo"] == .null)
        #expect(metadata["wax.project"] == nil || metadata["wax.project"] == .null)
    }
}

@Test
func explicitRepoAndProjectArgsWinOverClientCwd() async throws {
    let repoB = try makeGitRepo(named: "RepoB")
    defer { try? FileManager.default.removeItem(at: repoB) }

    try await withIsolatedBroker { service, _ in
        let write = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Explicit scope should beat inferred cwd"),
                "cwd": .string(repoB.path),
                "repo": .string("explicit-repo"),
                "project": .string("explicit-project"),
            ]
        ))
        #expect(write.ok == true)

        let search = await service.handle(.init(
            command: "search",
            arguments: [
                "query": .string("Explicit scope should beat inferred cwd"),
                "mode": .string("text"),
                "topK": .int(5),
            ]
        ))
        #expect(search.ok == true)
        let hit = try #require(try requireObject(search.payload)["results"]?.arrayValue?.first?.objectValue)
        let metadata = try #require(hit["metadata"]?.objectValue)
        #expect(metadata["wax.repo"]?.stringValue == "explicit-repo")
        #expect(metadata["wax.project"]?.stringValue == "explicit-project")
    }
}

@Test
func sessionScopedRememberKeepsManifestProjectAndRepo() async throws {
    let repoB = try makeGitRepo(named: "RepoB")
    defer { try? FileManager.default.removeItem(at: repoB) }

    try await withIsolatedBroker { service, _ in
        let started = await service.handle(.init(
            command: "session_start",
            arguments: [
                "cwd": .string(repoB.path),
                "agent_id": .string("p05-agent"),
                "run_id": .string("p05-run"),
            ]
        ))
        #expect(started.ok == true)
        let sessionID = try requireString(try requireObject(started.payload), "session_id")

        let other = try makeGitRepo(named: "OtherRepo")
        defer { try? FileManager.default.removeItem(at: other) }

        let write = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Session scoped write must keep manifest repo"),
                "session_id": .string(sessionID),
                "cwd": .string(other.path),
            ]
        ))
        #expect(write.ok == true)

        let search = await service.handle(.init(
            command: "memory_search",
            arguments: [
                "query": .string("Session scoped write must keep manifest repo"),
                "session_id": .string(sessionID),
                "include_working": .bool(true),
                "include_durable": .bool(false),
                "include_episodic": .bool(false),
            ]
        ))
        #expect(search.ok == true)
        let hit = try #require(try requireObject(search.payload)["results"]?.arrayValue?.first?.objectValue)
        let metadata = try #require(hit["metadata"]?.objectValue)
        #expect(metadata["wax.repo"]?.stringValue == repoB.lastPathComponent)
        #expect(metadata["wax.project"]?.stringValue == repoB.lastPathComponent)
    }
}

@Test
func statsDoesNotAdvertiseSiblingSessionAsPrimary() async throws {
    try await withIsolatedBroker { service, _ in
        let first = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("client-a"),
                "run_id": .string("run-a"),
            ]
        ))
        let second = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("client-b"),
                "run_id": .string("run-b"),
            ]
        ))
        #expect(first.ok == true)
        #expect(second.ok == true)
        let sessionA = try requireString(try requireObject(first.payload), "session_id")
        let sessionB = try requireString(try requireObject(second.payload), "session_id")

        let statsA = await service.handle(.init(
            command: "stats",
            arguments: ["session_id": .string(sessionA)]
        ))
        let statsB = await service.handle(.init(
            command: "stats",
            arguments: ["session_id": .string(sessionB)]
        ))
        #expect(statsA.ok == true)
        #expect(statsB.ok == true)

        let sessionObjectA = try #require(try requireObject(statsA.payload)["session"]?.objectValue)
        let sessionObjectB = try #require(try requireObject(statsB.payload)["session"]?.objectValue)
        #expect(sessionObjectA["session_id"]?.stringValue == sessionA)
        #expect(sessionObjectB["session_id"]?.stringValue == sessionB)
        #expect(sessionObjectA["session_id"]?.stringValue != sessionB)
        #expect(sessionObjectB["session_id"]?.stringValue != sessionA)

        _ = await service.handle(.init(
            command: "session_end",
            arguments: ["session_id": .string(sessionA)]
        ))
        let leftover = await service.handle(.init(command: "stats", arguments: [:]))
        #expect(leftover.ok == true)
        let leftoverSession = try #require(try requireObject(leftover.payload)["session"]?.objectValue)
        #expect(leftoverSession["session_id"] == nil || leftoverSession["session_id"] == .null)
        #expect(leftoverSession["session_id"]?.stringValue != sessionB)
    }
}

@Test
func statsIncludesReasonWhenEmbeddingStatusIsDegradedOrUnavailable() async throws {
    #expect(EmbeddingStatus.degraded(nil, reason: "some saved frames have no vectors").wireReason == "some saved frames have no vectors")
    #expect(EmbeddingStatus.unavailable(reason: "embedder failed to load").wireReason == "embedder failed to load")

    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-0128-degraded-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let seed = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false
    )
    let remembered = await seed.handle(.init(
        command: "remember",
        arguments: ["content": .string("Seed frame without vectors for degraded stats.")]
    ))
    #expect(remembered.ok == true)
    try await seed.close()

    let service = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: false,
        embedderChoice: "auto",
        requireVector: false,
        embedderOverride: StatsReasonEmbedder()
    )
    defer { Task { try? await service.close() } }

    let stats = await service.handle(.init(command: "stats", arguments: [:]))
    #expect(stats.ok == true)
    let payload = try requireObject(stats.payload)
    let status = try requireString(payload, "embeddingStatus")
    #expect(status == "degraded" || status == "unavailable")
    let reason = try requireString(payload, "embeddingStatusReason")
    #expect(reason.isEmpty == false)
}

@Test
func textSearchPreviewIsDehighlightedForHyphenatedToken() async throws {
    try await withIsolatedBroker { service, _ in
        let token = "STRESSCANARY-F91C3BFD"
        let write = await service.handle(.init(
            command: "remember",
            arguments: ["content": .string("Preview must contain \(token) exactly.")]
        ))
        #expect(write.ok == true)

        let search = await service.handle(.init(
            command: "search",
            arguments: [
                "query": .string(token),
                "mode": .string("text"),
                "topK": .int(5),
            ]
        ))
        #expect(search.ok == true)
        let results = try #require(try requireObject(search.payload)["results"]?.arrayValue)
        let preview = results.compactMap { $0.objectValue?["preview"]?.stringValue }.joined(separator: "\n")
        #expect(preview.contains(token))
        #expect(preview.contains("[STRESSCANARY]-[F91C3BFD]") == false)

        let corpus = await service.handle(.init(
            command: "corpus_search",
            arguments: [
                "query": .string(token),
                "mode": .string("text"),
                "topK": .int(5),
                "rebuild": .bool(true),
            ]
        ))
        #expect(corpus.ok == true)
        let corpusPreview = (try requireObject(corpus.payload)["results"]?.arrayValue ?? [])
            .compactMap { $0.objectValue?["preview"]?.stringValue }
            .joined(separator: "\n")
        #expect(corpusPreview.contains(token))
        #expect(corpusPreview.contains("[STRESSCANARY]-[F91C3BFD]") == false)
    }
}

@Test
func knowledgeCaptureReturnsEntityIdWhenKindMissing() async throws {
    try await withIsolatedBroker { service, _ in
        let upsert = await service.handle(.init(
            command: "entity_upsert",
            arguments: [
                "key": .string("subject:existing"),
                "kind": .string("person"),
                "aliases": .array([.string("existing-person")]),
            ]
        ))
        #expect(upsert.ok == true)
        let existingID = try #require(try requireObject(upsert.payload)["entity_id"]?.intValue)

        let captureExisting = await service.handle(.init(
            command: "knowledge_capture",
            arguments: [
                "content": .string("Existing subject should resolve without kind."),
                "subject": .string("subject:existing"),
            ]
        ))
        #expect(captureExisting.ok == true)
        let existingPayload = try requireObject(captureExisting.payload)
        #expect(existingPayload["entity_id"]?.intValue == existingID)

        let resolved = await service.handle(.init(
            command: "entity_resolve",
            arguments: ["alias": .string("existing-person")]
        ))
        #expect(resolved.ok == true)
        let entities = try #require(try requireObject(resolved.payload)["entities"]?.arrayValue)
        let kind = try #require(entities.first?.objectValue?["kind"]?.stringValue)
        #expect(kind == "person")

        let captureMissing = await service.handle(.init(
            command: "knowledge_capture",
            arguments: [
                "content": .string("Missing subject should upsert with default kind concept."),
                "subject": .string("subject:missing"),
            ]
        ))
        #expect(captureMissing.ok == true)
        let missingPayload = try requireObject(captureMissing.payload)
        #expect(missingPayload["entity_id"]?.intValue != nil)
        #expect(missingPayload["entity_skipped_reason"] == nil || missingPayload["entity_skipped_reason"] == .null)
    }
}

@Test
func markdownExportWithProjectOmitsOtherProjectsNotes() async throws {
    try await withIsolatedBroker { service, _ in
        let keep = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("KEEP-PROJECT note for markdown export"),
                "project": .string("KeepProj"),
                "durability": .string("durable"),
            ]
        ))
        let drop = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("DROP-PROJECT note for markdown export"),
                "project": .string("DropProj"),
                "durability": .string("durable"),
            ]
        ))
        #expect(keep.ok == true)
        #expect(drop.ok == true)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-md-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let export = await service.handle(.init(
            command: "markdown_export",
            arguments: [
                "output_dir": .string(outputURL.path),
                "project": .string("KeepProj"),
            ]
        ))
        #expect(export.ok == true)
        let keepRepo = try makeGitRepo(named: "KeepProj")
        let dropRepo = try makeGitRepo(named: "DropProj")
        defer {
            try? FileManager.default.removeItem(at: keepRepo)
            try? FileManager.default.removeItem(at: dropRepo)
        }

        let startKeep = await service.handle(.init(
            command: "session_start",
            arguments: ["cwd": .string(keepRepo.path), "agent_id": .string("keep-agent"), "run_id": .string("keep-run")]
        ))
        let startDrop = await service.handle(.init(
            command: "session_start",
            arguments: ["cwd": .string(dropRepo.path), "agent_id": .string("drop-agent"), "run_id": .string("drop-run")]
        ))
        #expect(startKeep.ok == true)
        #expect(startDrop.ok == true)
        let keepSession = try requireString(try requireObject(startKeep.payload), "session_id")
        let dropSession = try requireString(try requireObject(startDrop.payload), "session_id")

        let keepHandoff = await service.handle(.init(
            command: "handoff",
            arguments: [
                "content": .string("KEEP-SESSION-HANDOFF for markdown export"),
                "session_id": .string(keepSession),
            ]
        ))
        let dropHandoff = await service.handle(.init(
            command: "handoff",
            arguments: [
                "content": .string("DROP-SESSION-HANDOFF for markdown export"),
                "session_id": .string(dropSession),
            ]
        ))
        #expect(keepHandoff.ok == true)
        #expect(dropHandoff.ok == true)

        let memoryPath = try requireString(try requireObject(export.payload), "memory_md_path")
        let text = try String(contentsOfFile: memoryPath, encoding: .utf8)
        #expect(text.contains("KEEP-PROJECT"))
        #expect(text.contains("DROP-PROJECT") == false)

        let exportKeepSessions = await service.handle(.init(
            command: "markdown_export",
            arguments: [
                "output_dir": .string(outputURL.path),
                "project": .string(keepRepo.lastPathComponent),
            ]
        ))
        #expect(exportKeepSessions.ok == true)
        let handoffPath = try #require(try requireObject(exportKeepSessions.payload)["handoff_summary_path"]?.stringValue)
        let handoffText = try String(contentsOfFile: handoffPath, encoding: .utf8)
        #expect(handoffText.contains("KEEP-SESSION-HANDOFF"))
        #expect(handoffText.contains("DROP-SESSION-HANDOFF") == false)
    }
}

@Test
func rememberOversizeIsRejectedWithTypedContentLimit() async throws {
    try await withIsolatedBroker { service, _ in
        let oversized = String(repeating: "a", count: 131_073)
        let result = await service.handle(.init(
            command: "remember",
            arguments: ["content": .string(oversized)]
        ))
        #expect(result.ok == false)
        let message = result.error ?? ""
        #expect(message.contains("131072") || message.localizedCaseInsensitiveContains("maxContent"))
    }
}

@Test
func waxMCPServerCommandAdvertisesVersionAndHTTPBodyCap() throws {
    #expect(WaxMCPServerCommand.configuration.version == WaxMCPServerMetadata.version)
    let command = try WaxMCPServerCommand.parse([])
    #expect(command.httpMaxBodyBytes == 1_048_576)
}

private func firstTextContent(_ result: CallTool.Result) -> String {
    for content in result.content {
        if case .text(text: let text, annotations: _, _meta: _) = content {
            return text
        }
    }
    return ""
}

private func requireJSONObject(_ text: String) throws -> [String: Any] {
    let data = try #require(text.data(using: .utf8))
    let object = try JSONSerialization.jsonObject(with: data)
    return try #require(object as? [String: Any])
}
#endif

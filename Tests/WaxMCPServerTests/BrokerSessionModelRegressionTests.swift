import Foundation
import Testing

#if MCPServer
@testable import wax_mcp
@testable import Wax
@testable import WaxCore

private func withIsolatedBroker<T>(
    _ body: (AgentBrokerService, URL) async throws -> T
) async throws -> T {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-session-model-\(UUID().uuidString)", isDirectory: true)
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
        result.objectValue?["text"]?.stringValue ?? result.objectValue?["preview"]?.stringValue
    } ?? []
}

@Test
func sessionScopedRecallMergesDurableAndSessionNotes() async throws {
    try await withIsolatedBroker { service, _ in
        let started = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("recall-agent"),
                "run_id": .string("recall-run"),
            ]
        ))
        #expect(started.ok == true)
        let sessionID = try requireString(try requireObject(started.payload), "session_id")

        let durable = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("rv is a Zig CLI that evaluates policy and attaches an OS sandbox."),
                "memory_type": .string("decision"),
                "durability": .string("durable"),
            ]
        ))
        #expect(durable.ok == true)

        let sessionNote = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Session-only note: do not promote. CLEAN-TOKEN-20260818"),
                "session_id": .string(sessionID),
            ]
        ))
        #expect(sessionNote.ok == true)

        let scoped = await service.handle(.init(
            command: "recall",
            arguments: [
                "query": .string("What is rv?"),
                "session_id": .string(sessionID),
                "mode": .string("text"),
                "scope": .string("global"),
                "limit": .int(10),
            ]
        ))
        #expect(scoped.ok == true, "scoped recall failed: \(scoped.error ?? "nil")")
        let payload = try requireObject(scoped.payload)
        let texts = resultTexts(payload)
        #expect(texts.contains { $0.contains("Zig CLI") && $0.contains("policy") })
        #expect(texts.contains { $0.contains("CLEAN-TOKEN-20260818") })
    }
}

@Test
func sessionStartReusesActiveSessionForSameAgentAndRun() async throws {
    try await withIsolatedBroker { service, _ in
        let first = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("same-agent"),
                "run_id": .string("same-run"),
            ]
        ))
        #expect(first.ok == true)
        let firstPayload = try requireObject(first.payload)
        let firstID = try requireString(firstPayload, "session_id")

        let second = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("same-agent"),
                "run_id": .string("same-run"),
            ]
        ))
        #expect(second.ok == true)
        let secondPayload = try requireObject(second.payload)
        #expect(try requireString(secondPayload, "session_id") == firstID)
        #expect(secondPayload["resumed"]?.boolValue == true)
    }
}

private func waxFileSize(at path: String) throws -> UInt64 {
    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    let size = try #require(attrs[.size] as? NSNumber)
    return size.uint64Value
}

/// Header region + footer + empty TOC. Not a 16 MiB cap.
private let sessionWalLayoutSlack: UInt64 =
    Constants.headerRegionSize + Constants.footerSize + 32 * 1024

private func expectSessionStoreNearSessionWal(_ size: UInt64) {
    let wal = Constants.sessionWalSize
    #expect(size >= wal)
    #expect(size <= wal + sessionWalLayoutSlack)
}

@Test
func sessionStartCreatesSessionStoreWithSmallWal() async throws {
    try await withIsolatedBroker { service, sessionRoot in
        let started = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("wal-agent"),
                "run_id": .string("wal-run"),
            ]
        ))
        #expect(started.ok == true)
        let payload = try requireObject(started.payload)
        let storePath = try requireString(payload, "store_path")
        expectSessionStoreNearSessionWal(try waxFileSize(at: storePath))

        let reused = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("wal-agent"),
                "run_id": .string("wal-run"),
            ]
        ))
        #expect(reused.ok == true)
        let reusedPayload = try requireObject(reused.payload)
        let startedID = try requireString(payload, "session_id")
        #expect(try requireString(reusedPayload, "session_id") == startedID)
        #expect(reusedPayload["resumed"]?.boolValue == true)
        #expect(try requireString(reusedPayload, "store_path") == storePath)

        let waxFiles = try FileManager.default.contentsOfDirectory(atPath: sessionRoot.path)
            .filter { $0.hasSuffix(".wax") }
        #expect(waxFiles.count == 1)
        expectSessionStoreNearSessionWal(try waxFileSize(at: storePath))

        let stats = await service.handle(.init(command: "stats"))
        #expect(stats.ok == true)
        let longTermPath = try requireString(try requireObject(stats.payload), "storePath")
        let longTermSize = try waxFileSize(at: longTermPath)
        #expect(longTermSize > Constants.sessionWalSize)
        #expect(longTermSize >= Constants.defaultWalSize)
    }
}

@Test
func sessionEndIdleReportsConsistentKeys() async throws {
    try await withIsolatedBroker { service, _ in
        let ended = await service.handle(.init(command: "session_end"))
        #expect(ended.ok == true, "idle session_end failed: \(ended.error ?? "nil")")
        let payload = try requireObject(ended.payload)
        #expect(payload["status"]?.stringValue == "ok")
        #expect(payload["session_id"] == .null)
        #expect(payload["ended"]?.boolValue == false)
        #expect(payload["active"]?.boolValue == false)
        #expect(payload["remaining_active"]?.boolValue == false)
        #expect(payload["active_session_count"]?.intValue == 0)
    }
}

@Test
func sessionEndMarksThatSessionInactiveWhenSiblingRemains() async throws {
    try await withIsolatedBroker { service, _ in
        let first = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("end-agent-a"),
                "run_id": .string("end-run-a"),
            ]
        ))
        #expect(first.ok == true)
        let firstID = try requireString(try requireObject(first.payload), "session_id")

        let second = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("end-agent-b"),
                "run_id": .string("end-run-b"),
            ]
        ))
        #expect(second.ok == true)
        let secondID = try requireString(try requireObject(second.payload), "session_id")
        #expect(firstID != secondID)

        let ended = await service.handle(.init(
            command: "session_end",
            arguments: ["session_id": .string(firstID)]
        ))
        #expect(ended.ok == true, "session_end failed: \(ended.error ?? "nil")")
        let payload = try requireObject(ended.payload)
        #expect(try requireString(payload, "session_id") == firstID)
        #expect(payload["ended"]?.boolValue == true)
        #expect(payload["active"]?.boolValue == false)
        #expect(payload["remaining_active"]?.boolValue == true)
        #expect(payload["active_session_count"]?.intValue == 1)
    }
}

@Test
func sessionStartInfersProjectFromClientCwdNotBrokerBinary() async throws {
    try await withIsolatedBroker { service, _ in
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: repo) }

        let started = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("cwd-agent"),
                "run_id": .string("cwd-run"),
                "cwd": .string(repo.path),
            ]
        ))
        #expect(started.ok == true)
        let payload = try requireObject(started.payload)
        #expect(payload["project"]?.stringValue == repo.lastPathComponent)
        #expect(payload["project"]?.stringValue != "Wax")
        #expect(payload["repo"]?.stringValue == repo.lastPathComponent)

        let sessionID = try requireString(payload, "session_id")
        let write = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Session write should inherit the client cwd project, not the daemon cwd."),
                "session_id": .string(sessionID),
            ]
        ))
        #expect(write.ok == true)

        let search = await service.handle(.init(
            command: "memory_search",
            arguments: [
                "query": .string("inherit the client cwd project"),
                "session_id": .string(sessionID),
                "include_working": .bool(true),
                "include_durable": .bool(false),
                "include_episodic": .bool(false),
            ]
        ))
        #expect(search.ok == true)
        let hit = try #require(try requireObject(search.payload)["results"]?.arrayValue?.first?.objectValue)
        let metadata = try #require(hit["metadata"]?.objectValue)
        #expect(metadata["wax.project"]?.stringValue == repo.lastPathComponent)
        #expect(metadata["wax.repo"]?.stringValue == repo.lastPathComponent)
    }
}

@Test
func corpusSearchIncludesDurableLongTermFrames() async throws {
    try await withIsolatedBroker { service, _ in
        let write = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("DCG is the destructive command guard for ryk policy evaluation."),
                "memory_type": .string("fact"),
                "durability": .string("durable"),
            ]
        ))
        #expect(write.ok == true)

        let corpus = await service.handle(.init(
            command: "corpus_search",
            arguments: [
                "query": .string("rv DCG"),
                "mode": .string("text"),
                "topK": .int(8),
                "rebuild": .bool(false),
            ]
        ))
        #expect(corpus.ok == true, "corpus_search failed: \(corpus.error ?? "nil")")
        let payload = try requireObject(corpus.payload)
        let texts = resultTexts(payload)
        #expect(texts.contains { $0.contains("destructive command guard") })
    }
}

@Test
func memorySearchWithoutSessionIDStillSearchesDurableWhenMultipleSessionsAreActive() async throws {
    try await withIsolatedBroker { service, _ in
        let first = await service.handle(.init(command: "session_start"))
        let second = await service.handle(.init(command: "session_start"))
        #expect(first.ok == true)
        #expect(second.ok == true)

        let token = "minilmdimscanary\(UUID().uuidString.prefix(8).lowercased())"
        let write = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Durable fact \(token) about MiniLM dimensions."),
                "memory_type": .string("fact"),
                "durability": .string("durable"),
            ]
        ))
        #expect(write.ok == true)

        let search = await service.handle(.init(
            command: "memory_search",
            arguments: [
                "query": .string(token),
                "mode": .string("text"),
                "include_working": .bool(true),
                "include_durable": .bool(true),
            ]
        ))
        #expect(search.ok == true, "memory_search failed: \(search.error ?? "nil")")
        let payload = try requireObject(search.payload)
        let texts = resultTexts(payload)
        let display = payload["display_text"]?.stringValue ?? ""
        #expect(
            texts.contains { $0.localizedCaseInsensitiveContains(token) } || display.localizedCaseInsensitiveContains(token),
            "expected durable hit for \(token); display=\(display) texts=\(texts)"
        )
    }
}

@Test
func sessionSynthesizeWithMultipleSessionsAsksForSessionIDNotMissingSession() async throws {
    try await withIsolatedBroker { service, _ in
        #expect((await service.handle(.init(command: "session_start"))).ok == true)
        #expect((await service.handle(.init(command: "session_start"))).ok == true)

        let synthesized = await service.handle(.init(command: "session_synthesize"))
        #expect(synthesized.ok == false)
        #expect((synthesized.error ?? "").contains("more than one session is active"))
        #expect(!(synthesized.error ?? "").contains("no active session is available"))
    }
}

@Test
func memoryPromoteDoesNotRecommendDoNotPromoteCanaryAfterOneRecall() async throws {
    try await withIsolatedBroker { service, _ in
        let started = await service.handle(.init(command: "session_start"))
        let sessionID = try requireString(try requireObject(started.payload), "session_id")
        let canary = "Session-only note: do not promote. CLEAN-TOKEN-20260818"

        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string(canary),
                "session_id": .string(sessionID),
            ]
        ))).ok == true)

        #expect((await service.handle(.init(
            command: "recall",
            arguments: [
                "query": .string(canary),
                "session_id": .string(sessionID),
                "mode": .string("text"),
            ]
        ))).ok == true)

        let promote = await service.handle(.init(
            command: "memory_promote",
            arguments: ["session_id": .string(sessionID)]
        ))
        #expect(promote.ok == true)
        let payload = try requireObject(promote.payload)
        let proposal = try requireObject(payload["proposal"])
        #expect(proposal["should_write"]?.boolValue == false)
    }
}

@Test
func recallRejectsEmptyQuery() async throws {
    try await withIsolatedBroker { service, _ in
        let empty = await service.handle(.init(
            command: "recall",
            arguments: ["query": .string("   ")]
        ))
        #expect(empty.ok == false)
        #expect((empty.error ?? "").contains("query"))
    }
}

@Test
func searchRejectsAlphaUnlessHybrid() async throws {
    try await withIsolatedBroker { service, _ in
        let rejected = await service.handle(.init(
            command: "search",
            arguments: [
                "query": .string("alpha"),
                "mode": .string("text"),
                "alpha": .double(0.7),
            ]
        ))
        #expect(rejected.ok == false)
        #expect((rejected.error ?? "").contains("alpha"))
    }
}

@Test
func factsQueryOmitsSentinelAsOfWhenCallerDidNotPassOne() async throws {
    try await withIsolatedBroker { service, _ in
        #expect((await service.handle(.init(
            command: "fact_assert",
            arguments: [
                "subject": .string("wax"),
                "predicate": .string("status"),
                "object": .string("open"),
            ]
        ))).ok == true)

        let queried = await service.handle(.init(command: "facts_query"))
        #expect(queried.ok == true)
        let payload = try requireObject(queried.payload)
        #expect(payload["as_of"] == .null || payload["as_of"] == nil)
        if let raw = payload["as_of"]?.intValue {
            #expect(raw != Int64.max)
        }
    }
}

@Test
func compactContextIncludesLiveSessionNote() async throws {
    try await withIsolatedBroker { service, _ in
        let started = await service.handle(.init(command: "session_start"))
        let sessionID = try requireString(try requireObject(started.payload), "session_id")
        let token = "COMPACT-LIVE-\(UUID().uuidString.prefix(8))"

        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Working session note \(token) must appear in short context."),
                "session_id": .string(sessionID),
            ]
        ))).ok == true)

        let compact = await service.handle(.init(
            command: "compact_context",
            arguments: [
                "query": .string("unrelated compact query"),
                "session_id": .string(sessionID),
                "mode": .string("text"),
                "token_budget": .int(800),
            ]
        ))
        #expect(compact.ok == true, "compact_context failed: \(compact.error ?? "nil")")
        let payload = try requireObject(compact.payload)
        let short = payload["short_context"]?.arrayValue ?? []
        #expect(short.contains { $0.objectValue?["preview"]?.stringValue?.contains(token) == true
            || $0.objectValue?["text"]?.stringValue?.contains(token) == true })
    }
}

@Test
func defaultMemorySearchDoesNotReturnOtherSessionsEndedNoteWhenMultipleSessionsAreLive() async throws {
    try await withIsolatedBroker { service, _ in
        let ended = await service.handle(.init(command: "session_start"))
        #expect(ended.ok == true)
        let endedID = try requireString(try requireObject(ended.payload), "session_id")
        let token = "ENDED-WORKING-\(UUID().uuidString.prefix(8))"

        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Ended-session working note \(token) must not leak unscoped."),
                "session_id": .string(endedID),
            ]
        ))).ok == true)
        #expect((await service.handle(.init(
            command: "session_end",
            arguments: ["session_id": .string(endedID)]
        ))).ok == true)

        #expect((await service.handle(.init(command: "session_start"))).ok == true)
        #expect((await service.handle(.init(command: "session_start"))).ok == true)

        let search = await service.handle(.init(
            command: "memory_search",
            arguments: [
                "query": .string(token),
                "mode": .string("text"),
            ]
        ))
        #expect(search.ok == true, "memory_search failed: \(search.error ?? "nil")")
        let payload = try requireObject(search.payload)
        let texts = resultTexts(payload)
        let display = payload["display_text"]?.stringValue ?? ""
        #expect(!texts.contains { $0.contains(token) })
        #expect(!display.contains(token))
        #expect(!(payload["results"]?.arrayValue ?? []).contains { result in
            result.objectValue?["horizon"]?.stringValue == "episodic"
                && (result.objectValue?["text"]?.stringValue?.contains(token) == true
                    || result.objectValue?["preview"]?.stringValue?.contains(token) == true)
        })
    }
}

@Test
func mergeRecallItemsReservesMissingSessionHorizonWhenDurableFillsLimit() {
    let durable = (1...5).map { index in
        recallItem(frameId: UInt64(index), score: 1.0 - Float(index) * 0.01, text: "durable hit \(index)")
    }
    let session = [recallItem(frameId: 99, score: 0.05, text: "session reserved note")]
    let merged = LayeredRecall.mergeRecallItems(
        sessionItems: session,
        durableItems: durable,
        limit: 5
    )
    #expect(merged.count == 5)
    #expect(merged.contains { $0.text.contains("session reserved note") })
    #expect(merged.contains { $0.explanations.contains("current session") })
    #expect(merged.contains { $0.explanations.contains("durable memory") })
}

@Test
func mergeRecallItemsReservesMissingDurableHorizonWhenSessionFillsLimit() {
    let session = (1...5).map { index in
        recallItem(frameId: UInt64(index), score: 1.0 - Float(index) * 0.01, text: "session hit \(index)")
    }
    let durable = [recallItem(frameId: 99, score: 0.05, text: "durable reserved note")]
    let merged = LayeredRecall.mergeRecallItems(
        sessionItems: session,
        durableItems: durable,
        limit: 5
    )
    #expect(merged.count == 5)
    #expect(merged.contains { $0.text.contains("durable reserved note") })
    #expect(merged.contains { $0.explanations.contains("current session") })
    #expect(merged.contains { $0.explanations.contains("durable memory") })
}

@Test
func filterBeforeMergeKeepsProjectHitWhenForeignRanksFillLimit() {
    let foreign = (1...8).map { index in
        recallItem(
            frameId: UInt64(index),
            score: 0.99 - Float(index) * 0.01,
            text: "FOREIGN-STARVE shared query token \(index)",
            metadata: [MemoryMetadataKeys.project: "OtherLand"]
        )
    }
    let home = recallItem(
        frameId: 100,
        score: 0.20,
        text: "HOME-PROJECT-TOKEN shared query token decision",
        metadata: [MemoryMetadataKeys.project: "HomeLand"]
    )

    // Wrong order (filter after merge/limit): home frame is starved out.
    let starved = LayeredRecall.filterRecallItemsByProject(
        LayeredRecall.mergeRecallItems(sessionItems: [], durableItems: foreign + [home], limit: 3),
        project: "HomeLand",
        repo: nil
    )
    #expect(starved.isEmpty)

    // Correct order (filter before merge/limit): home frame survives.
    let filtered = LayeredRecall.filterRecallItemsByProject(
        foreign + [home],
        project: "HomeLand",
        repo: nil
    )
    let kept = LayeredRecall.mergeRecallItems(
        sessionItems: [],
        durableItems: filtered,
        limit: 3
    )
    #expect(kept.contains { $0.text.contains("HOME-PROJECT-TOKEN") })
    #expect(!kept.contains { $0.text.contains("FOREIGN-STARVE") })
}

@Test
func frameFilterByAddingProjectScopeMergesMetadataEntries() {
    let base = FrameFilter(
        metadataFilter: MetadataFilter(requiredEntries: ["topic": "keep"])
    )
    let scoped = LayeredRecall.frameFilterForScopedRetrieval(
        base: base,
        scope: .project,
        identity: LayeredRecall.Identity(project: "HomeLand", repo: nil)
    )
    #expect(scoped?.metadataFilter?.requiredEntries[MemoryMetadataKeys.project] == "HomeLand")
    #expect(scoped?.metadataFilter?.requiredEntries["topic"] == "keep")
}

@Test
func recallAppliesFrameFilterToDurableHitsWhenSessionIDIsSet() async throws {
    try await withIsolatedBroker { service, _ in
        let started = await service.handle(.init(command: "session_start"))
        let sessionID = try requireString(try requireObject(started.payload), "session_id")
        let token = "FILTER-DURABLE-\(UUID().uuidString.prefix(8))"

        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("\(token) keep this durable fact"),
                "memory_type": .string("fact"),
                "durability": .string("durable"),
                "metadata": .object(["topic": .string("keep")]),
            ]
        ))).ok == true)
        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("\(token) drop this durable fact"),
                "memory_type": .string("fact"),
                "durability": .string("durable"),
                "metadata": .object(["topic": .string("drop")]),
            ]
        ))).ok == true)
        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("\(token) session note without topic"),
                "session_id": .string(sessionID),
            ]
        ))).ok == true)

        let recalled = await service.handle(.init(
            command: "recall",
            arguments: [
                "query": .string(token),
                "session_id": .string(sessionID),
                "mode": .string("text"),
                "limit": .int(10),
                "filters": .object([
                    "metadata": .object(["topic": .string("keep")]),
                ]),
            ]
        ))
        #expect(recalled.ok == true, "recall failed: \(recalled.error ?? "nil")")
        let texts = resultTexts(try requireObject(recalled.payload))
        #expect(texts.contains { $0.contains("keep this durable fact") })
        #expect(!texts.contains { $0.contains("drop this durable fact") })
    }
}

@Test
func recallRecordsRetrievalHitsOnlyForSessionHorizonItems() async throws {
    try await withIsolatedBroker { service, sessionRootURL in
        let started = await service.handle(.init(command: "session_start"))
        let startedPayload = try requireObject(started.payload)
        let sessionID = try requireString(startedPayload, "session_id")
        let sessionUUID = try #require(UUID(uuidString: sessionID))
        let token = "HIT-SCOPE-\(UUID().uuidString.prefix(8))"

        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Decoy session note that must not inherit durable frame hits."),
                "session_id": .string(sessionID),
            ]
        ))).ok == true)
        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("\(token) session mention that should be recorded."),
                "session_id": .string(sessionID),
            ]
        ))).ok == true)
        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("\(token) durable fact that shares no session store."),
                "memory_type": .string("fact"),
                "durability": .string("durable"),
            ]
        ))).ok == true)

        let scopedWorking = await service.handle(.init(
            command: "memory_search",
            arguments: [
                "query": .string(token),
                "session_id": .string(sessionID),
                "mode": .string("text"),
                "include_working": .bool(true),
                "include_episodic": .bool(false),
                "include_durable": .bool(false),
            ]
        ))
        #expect(scopedWorking.ok == true)
        let workingHits = try requireObject(scopedWorking.payload)["results"]?.arrayValue ?? []
        let sessionFrameIDs = Set(workingHits.compactMap { $0.objectValue?["frame_id"]?.intValue }.map(UInt64.init))
        #expect(!sessionFrameIDs.isEmpty)

        let recalled = await service.handle(.init(
            command: "recall",
            arguments: [
                "query": .string(token),
                "session_id": .string(sessionID),
                "mode": .string("text"),
                "limit": .int(10),
            ]
        ))
        #expect(recalled.ok == true, "recall failed: \(recalled.error ?? "nil")")
        let recallPayload = try requireObject(recalled.payload)
        let recallTexts = resultTexts(recallPayload)
        #expect(recallTexts.contains { $0.contains("durable fact") })
        #expect(recallTexts.contains { $0.contains("session mention") })

        let manifest = try BrokerSessionPersistence.loadManifest(rootURL: sessionRootURL, sessionID: sessionUUID)
        let events = try BrokerSessionPersistence.loadEvents(from: URL(fileURLWithPath: manifest.eventLogPath))
        let recordedFrameIDs = Set(events.compactMap { event -> UInt64? in
            guard event.kind == .retrievalHit else { return nil }
            return event.payload["frame_id"].flatMap(UInt64.init)
        })
        #expect(!recordedFrameIDs.isEmpty)
        #expect(recordedFrameIDs.isSubset(of: sessionFrameIDs))
    }
}

@Test
func coldRememberReturnsPendingThenFrameLandsWhenDeferredEmbedderBecomesReady() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-pending-remember-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let gate = EmbedderGate()
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
        return PendingRememberTestEmbedder()
    }
    do {
        let token = "PENDINGLAND\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
        let rememberTask = Task {
            await service.handle(.init(
                command: "remember",
                arguments: ["content": .string("Cold remember \(token) should land after embedder ready.")]
            ))
        }

        try await Task.sleep(for: .milliseconds(40))
        let earlySearch = await service.handle(.init(
            command: "search",
            arguments: [
                "query": .string(token),
                "mode": .string("text"),
                "topK": .int(5),
            ]
        ))
        #expect(earlySearch.ok == true, "early search failed: \(earlySearch.error ?? "nil")")
        let earlyPayload = try requireObject(earlySearch.payload)
        let earlyTexts = resultTexts(earlyPayload)
        let earlyDisplay = earlyPayload["display_text"]?.stringValue ?? ""
        #expect(
            !earlyTexts.contains { $0.contains(token) } && !earlyDisplay.contains(token),
            "frame must stay absent until the automatic factory opens; display=\(earlyDisplay) texts=\(earlyTexts)"
        )

        await gate.open()
        let remembered = await rememberTask.value
        #expect(remembered.ok == true, "remember failed: \(remembered.error ?? "nil")")
        let rememberPayload = try requireObject(remembered.payload)
        #expect(rememberPayload["status"]?.stringValue == "ok")
        #expect((rememberPayload["framesAdded"]?.intValue ?? 0) >= 1)

        #expect((await service.handle(.init(command: "flush"))).ok == true)

        let search = await service.handle(.init(
            command: "search",
            arguments: [
                "query": .string(token),
                "mode": .string("vector"),
                "topK": .int(5),
            ]
        ))
        #expect(search.ok == true, "search failed: \(search.error ?? "nil")")
        let searchPayload = try requireObject(search.payload)
        let texts = resultTexts(searchPayload)
        let display = searchPayload["display_text"]?.stringValue ?? ""
        #expect(searchPayload["query_embedding_state"]?.stringValue == "available")
        #expect(
            texts.contains { $0.contains(token) } || display.contains(token),
            "expected vector-backed frame for \(token); display=\(display) texts=\(texts)"
        )
        try await service.close()
    } catch {
        try? await service.close()
        throw error
    }
}

@Test
func coldRememberPendingWriteSurfacesTypedFailureWhenEmbedderFails() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-pending-fail-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let gate = EmbedderGate()
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
        throw PendingRememberFactoryError.unavailable
    }
    do {
        let rememberTask = Task {
            await service.handle(.init(
                command: "remember",
                arguments: ["content": .string("Cold remember should surface embedder failure.")]
            ))
        }
        try await Task.sleep(for: .milliseconds(40))
        await gate.open()
        let remembered = await rememberTask.value
        #expect(remembered.ok == false)
        #expect(
            (remembered.error ?? "").localizedCaseInsensitiveContains("embed")
                || (remembered.error ?? "").localizedCaseInsensitiveContains("unavailable")
                || (remembered.error ?? "").localizedCaseInsensitiveContains("not ready")
        )
        try await service.close()
    } catch {
        try? await service.close()
        throw error
    }
}

@Test
func requireVectorOpenPreservesBuiltInTimeoutError() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-require-vector-timeout-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    do {
        _ = try await AgentBrokerService(
            storePath: storeURL.path,
            sessionRootPath: sessionRootURL.path,
            noEmbedder: false,
            embedderChoice: "minilm",
            requireVector: true,
            readiness: EmbeddingReadiness()
        ) {
            throw BuiltInEmbeddingProviderError.timedOut(.miniLM)
        }
        Issue.record("require-vector open should preserve BuiltInEmbeddingProviderError.timedOut")
    } catch let error as BuiltInEmbeddingProviderError {
        #expect(error == .timedOut(.miniLM))
    } catch {
        Issue.record("expected BuiltInEmbeddingProviderError.timedOut, got \(error)")
    }
}

@Test
func requireVectorOpenPreservesLockUnavailableError() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-require-vector-lock-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    var config = OrchestratorConfig.default
    config.enableVectorSearch = false
    let holder = try await MemoryOrchestrator(at: storeURL, config: config)
    defer { Task { try? await holder.close() } }

    setenv("WAX_LOCK_TIMEOUT_SECS", "0.2", 1)
    defer { unsetenv("WAX_LOCK_TIMEOUT_SECS") }

    do {
        _ = try await AgentBrokerService(
            storePath: storeURL.path,
            sessionRootPath: sessionRootURL.path,
            noEmbedder: false,
            embedderChoice: "minilm",
            requireVector: true,
            readiness: EmbeddingReadiness()
        ) {
            PendingRememberTestEmbedder()
        }
        Issue.record("require-vector open should preserve WaxError.lockUnavailable")
    } catch let error as WaxError {
        guard case .lockUnavailable = error else {
            Issue.record("expected WaxError.lockUnavailable, got \(error)")
            return
        }
    } catch {
        Issue.record("expected WaxError.lockUnavailable, got \(error)")
    }
}

@Test
func handleRejectsInvalidSessionIDUUID() async throws {
    try await withIsolatedBroker { service, _ in
        let rejected = await service.handle(.init(
            command: "search",
            arguments: [
                "query": .string("x"),
                "mode": .string("text"),
                "session_id": .string("not-a-uuid"),
            ]
        ))
        #expect(rejected.ok == false)
        #expect((rejected.error ?? "").contains("session_id must be a valid UUID"))
    }
}

@Test
func sessionStartDoesNotImplicitlyScopeUnscopedWrites() async throws {
    try await withIsolatedBroker { service, _ in
        let started = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("scope-agent"),
                "run_id": .string("scope-run"),
            ]
        ))
        #expect(started.ok == true)
        let sessionID = try requireString(try requireObject(started.payload), "session_id")

        #expect((await service.handle(.init(
            command: "remember",
            arguments: ["content": .string("GLOBAL_IMPLICIT_SCOPE_GUARD")]
        ))).ok == true)
        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("SESSION_EXPLICIT_SCOPE_GUARD"),
                "session_id": .string(sessionID),
            ]
        ))).ok == true)

        let scoped = await service.handle(.init(
            command: "search",
            arguments: [
                "query": .string("GLOBAL_IMPLICIT_SCOPE_GUARD"),
                "mode": .string("text"),
                "topK": .int(10),
                "session_id": .string(sessionID),
            ]
        ))
        #expect(scoped.ok == true)
        let scopedTexts = resultTexts(try requireObject(scoped.payload))
        #expect(scopedTexts.contains { $0.contains("GLOBAL_IMPLICIT_SCOPE_GUARD") } == false)

        let unscoped = await service.handle(.init(
            command: "search",
            arguments: [
                "query": .string("GLOBAL_IMPLICIT_SCOPE_GUARD"),
                "mode": .string("text"),
                "topK": .int(10),
            ]
        ))
        #expect(unscoped.ok == true)
        let unscopedTexts = resultTexts(try requireObject(unscoped.payload))
        #expect(unscopedTexts.contains { $0.contains("GLOBAL_IMPLICIT_SCOPE_GUARD") })
    }
}

@Test
func endedSessionIDIsRejectedOnLaterScopedBrokerCalls() async throws {
    try await withIsolatedBroker { service, _ in
        let started = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("ended-agent"),
                "run_id": .string("ended-run"),
            ]
        ))
        let sessionID = try requireString(try requireObject(started.payload), "session_id")
        #expect((await service.handle(.init(
            command: "session_end",
            arguments: ["session_id": .string(sessionID)]
        ))).ok == true)

        let remember = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("should fail after end"),
                "session_id": .string(sessionID),
            ]
        ))
        #expect(remember.ok == false)
        #expect((remember.error ?? "").contains("has ended") || (remember.error ?? "").contains("session_ended"))

        let search = await service.handle(.init(
            command: "search",
            arguments: [
                "query": .string("should fail after end"),
                "mode": .string("text"),
                "topK": .int(5),
                "session_id": .string(sessionID),
            ]
        ))
        #expect(search.ok == false)
        #expect((search.error ?? "").contains("has ended") || (search.error ?? "").contains("session_ended"))
    }
}

@Test
func sessionEndRequiresSessionIDWhenMultipleSessionsAreActive() async throws {
    try await withIsolatedBroker { service, _ in
        #expect((await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("multi-end-a"),
                "run_id": .string("run-a"),
            ]
        ))).ok == true)
        #expect((await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("multi-end-b"),
                "run_id": .string("run-b"),
            ]
        ))).ok == true)

        let ended = await service.handle(.init(command: "session_end"))
        #expect(ended.ok == false)
        #expect((ended.error ?? "").contains("session_id is required"))
    }
}

@Test
func memorySearchWorkingOnlyExcludesDurableHits() async throws {
    try await withIsolatedBroker { service, _ in
        let started = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("filter-agent"),
                "run_id": .string("filter-run"),
            ]
        ))
        let sessionID = try requireString(try requireObject(started.payload), "session_id")
        let query = "F033_POST_FILTER_ANCHOR"

        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("\(query) \(query) \(query) durable result should be filtered out"),
                "memory_type": .string("fact"),
                "durability": .string("durable"),
            ]
        ))).ok == true)
        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("\(query) working result should survive filtering"),
                "session_id": .string(sessionID),
            ]
        ))).ok == true)

        let search = await service.handle(.init(
            command: "memory_search",
            arguments: [
                "query": .string(query),
                "mode": .string("text"),
                "topK": .int(1),
                "session_id": .string(sessionID),
                "include_working": .bool(true),
                "include_episodic": .bool(false),
                "include_durable": .bool(false),
            ]
        ))
        #expect(search.ok == true, "memory_search failed: \(search.error ?? "nil")")
        let texts = resultTexts(try requireObject(search.payload))
        #expect(texts.count == 1)
        #expect(texts.contains { $0.contains("working result should survive filtering") })
        #expect(texts.contains { $0.contains("durable result should be filtered out") } == false)
    }
}

@Test
func sessionSynthesizeAndPromoteFlowWorksOnBroker() async throws {
    try await withIsolatedBroker { service, _ in
        let started = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("synth-agent"),
                "run_id": .string("synth-run"),
            ]
        ))
        let sessionID = try requireString(try requireObject(started.payload), "session_id")
        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "session_id": .string(sessionID),
                "content": .string("Decision: Wax should default repo-scoped recall before global recall."),
            ]
        ))).ok == true)

        let synthesize = await service.handle(.init(
            command: "session_synthesize",
            arguments: ["session_id": .string(sessionID)]
        ))
        #expect(synthesize.ok == true, "session_synthesize failed: \(synthesize.error ?? "nil")")
        let candidates = try requireObject(synthesize.payload)["durable_candidates"]?.arrayValue ?? []
        #expect(!candidates.isEmpty)

        let promote = await service.handle(.init(
            command: "memory_promote",
            arguments: [
                "session_id": .string(sessionID),
                "approve": .bool(true),
            ]
        ))
        #expect(promote.ok == true, "memory_promote failed: \(promote.error ?? "nil")")
    }
}

@Test
func memoryPromotePreservesLockedOverrideOnBroker() async throws {
    try await withIsolatedBroker { service, _ in
        let started = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("lock-agent"),
                "run_id": .string("lock-run"),
            ]
        ))
        let sessionID = try requireString(try requireObject(started.payload), "session_id")
        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "session_id": .string(sessionID),
                "content": .string("Decision: keep broker-backed promotion overrides intact."),
            ]
        ))).ok == true)

        let promote = await service.handle(.init(
            command: "memory_promote",
            arguments: [
                "session_id": .string(sessionID),
                "approve": .bool(true),
                "locked": .bool(true),
            ]
        ))
        #expect(promote.ok == true, "memory_promote failed: \(promote.error ?? "nil")")
        let metadata = try requireObject(try requireObject(promote.payload)["metadata"] ?? .null)
        #expect(metadata["wax.durability"]?.stringValue == "locked")
    }
}

@Test
func handoffRoundTripWorksOnBroker() async throws {
    try await withIsolatedBroker { service, _ in
        let started = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("handoff-agent"),
                "run_id": .string("handoff-run"),
            ]
        ))
        let sessionID = try requireString(try requireObject(started.payload), "session_id")
        #expect((await service.handle(.init(
            command: "handoff",
            arguments: [
                "content": .string("Carry over refactor checkpoints"),
                "session_id": .string(sessionID),
                "project": .string("wax"),
                "pending_tasks": .array([.string("add graph tests"), .string("measure ranking drift")]),
            ]
        ))).ok == true)

        let latest = await service.handle(.init(
            command: "handoff_latest",
            arguments: ["project": .string("wax")]
        ))
        #expect(latest.ok == true)
        #expect(try requireObject(latest.payload)["content"]?.stringValue?.contains("Carry over refactor checkpoints") == true)
    }
}

@Test
func statsPayloadIncludesFramesWithoutVectors() async throws {
    try await withIsolatedBroker { service, _ in
        let response = await service.handle(.init(command: "stats"))
        #expect(response.ok == true, "stats failed: \(response.error ?? "nil")")

        let data = try JSONEncoder().encode(response)
        let json = try JSONSerialization.jsonObject(with: data)
        let responseObject = try #require(json as? [String: Any])
        let payload = try #require(responseObject["payload"] as? [String: Any])
        let framesWithoutVectors = try #require(payload["framesWithoutVectors"] as? NSNumber)
        #expect(framesWithoutVectors.int64Value >= 0)
    }
}

private func recallItem(
    frameId: UInt64,
    score: Float,
    text: String,
    metadata: [String: String] = [:]
) -> RAGContext.Item {
    RAGContext.Item(
        kind: .snippet,
        frameId: frameId,
        score: score,
        sources: [.text],
        text: text,
        metadata: metadata
    )
}

private enum PendingRememberFactoryError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Embedding provider is unavailable."
    }
}

private struct PendingRememberTestEmbedder: EmbeddingProvider {
    let dimensions = 8
    let normalize = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Test",
        model: "PendingRemember",
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

private actor EmbedderGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

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

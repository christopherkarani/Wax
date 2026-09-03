#if MCPServer
import Foundation
import MCP
import Testing
@testable import Wax
@testable import wax_mcp

private func withAgentDXRecallBroker<T>(
    _ body: (AgentBrokerService, URL) async throws -> T
) async throws -> T {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-dx-recall-\(UUID().uuidString)", isDirectory: true)
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

private func requireHits(_ payload: [String: AgentBrokerValue]) throws -> [[String: AgentBrokerValue]] {
    let rows = try #require(payload["results"]?.arrayValue)
    return try rows.map { try #require($0.objectValue) }
}

private func containsContentHash(_ value: AgentBrokerValue) -> Bool {
    switch value {
    case .object(let object):
        if object.keys.contains(where: { $0.localizedCaseInsensitiveContains("hash") }) {
            return true
        }
        return object.values.contains(where: containsContentHash)
    case .array(let values):
        return values.contains(where: containsContentHash)
    default:
        return false
    }
}

private func jsonObject(from result: CallTool.Result) throws -> [String: Any] {
    var text = ""
    for content in result.content {
        if case .text(text: let value, annotations: _, _meta: _) = content {
            text = value
            break
        }
    }
    guard let data = text.data(using: .utf8),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(
            domain: "WaxMCPAgentDXRecallTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Result is not a JSON object: \(text.prefix(200))"]
        )
    }
    return object
}

private func paddedCorpusBody(token: String, marker: String) -> String {
    "\(token) \(marker) " + String(repeating: "corpus-pad-\(marker)-", count: 40)
}

@Test
func compactRecallHitsCarryIdTextScopeAndAgeWithoutExplanationsOrHashes() async throws {
    try await withAgentDXRecallBroker { service, _ in
        let project = "dx-recall-\(UUID().uuidString.prefix(8))"
        let token = "WAXDXRECALL-\(UUID().uuidString.prefix(8))"
        let remembered = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Decision: keep \(token) as the compact recall gold token."),
                "memory_type": .string("decision"),
                "project": .string(project),
                "repo": .string(project),
            ]
        ))
        #expect(remembered.ok == true, "remember failed: \(remembered.error ?? "nil")")

        let recalled = await service.handle(.init(
            command: "recall",
            arguments: [
                "query": .string(token),
                "project": .string(project),
                "mode": .string("text"),
                "limit": .int(5),
            ]
        ))
        #expect(recalled.ok == true, "recall failed: \(recalled.error ?? "nil")")
        let payload = try requireObject(recalled.payload)
        let hits = try requireHits(payload)
        let hit = try #require(hits.first { object in
            (object["text"]?.stringValue ?? "").contains(token)
        })

        let text = try requireString(hit, "text")
        #expect(text.contains(token))
        let id = try requireString(hit, "id")
        #expect(id.hasPrefix("durable:"))
        let frameId = try #require(hit["frameId"]?.intValue)
        #expect(id == "durable:\(frameId)")
        #expect(try requireString(hit, "project") == project)
        #expect(try requireString(hit, "repo") == project)
        #expect(try requireString(hit, "memory_type") == "decision")
        #expect(hit["age_days"]?.intValue == 0)
        #expect(hit["score"]?.doubleValue != nil)
        #expect(hit["explanations"] == nil)
        #expect(hit["metadata"] == nil)
        #expect(containsContentHash(.object(hit)) == false)
    }
}

@Test
func compactMCPRecallJSONOmitsExplanationsAndHashes() async throws {
    try await withAgentDXRecallBroker { service, _ in
        let project = "dx-mcp-recall-\(UUID().uuidString.prefix(8))"
        let token = "WAXDXMCPRECALL-\(UUID().uuidString.prefix(8))"
        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Decision: \(token) must stay readable in compact MCP JSON."),
                "memory_type": .string("decision"),
                "project": .string(project),
                "repo": .string(project),
            ]
        ))).ok == true)

        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "recall",
                arguments: [
                    "query": .string(token),
                    "project": .string(project),
                    "mode": .string("text"),
                    "limit": .int(5),
                ]
            ),
            broker: service
        )
        #expect(result.isError != true)
        let payload = try jsonObject(from: result)
        let results = try #require(payload["results"] as? [[String: Any]])
        let hit = try #require(results.first { row in
            (row["text"] as? String)?.contains(token) == true
        })
        #expect((hit["id"] as? String)?.hasPrefix("durable:") == true)
        #expect(hit["project"] as? String == project)
        #expect(hit["repo"] as? String == project)
        #expect(hit["memory_type"] as? String == "decision")
        #expect(hit["age_days"] as? Int == 0 || (hit["age_days"] as? Int64) == 0)
        #expect(hit["score"] != nil)
        #expect(hit["explanations"] == nil)
        #expect(hit["metadata"] == nil)
    }
}

@Test
func verboseRecallKeepsExplanationsAndContentHashes() async throws {
    try await withAgentDXRecallBroker { service, _ in
        let project = "dx-verbose-\(UUID().uuidString.prefix(8))"
        let token = "WAXDXVERBOSE-\(UUID().uuidString.prefix(8))"
        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Decision: \(token) keeps explanations when verbose."),
                "memory_type": .string("decision"),
                "project": .string(project),
                "repo": .string(project),
            ]
        ))).ok == true)

        let recalled = await service.handle(.init(
            command: "recall",
            arguments: [
                "query": .string(token),
                "project": .string(project),
                "mode": .string("text"),
                "limit": .int(5),
                "verbosity": .string("verbose"),
            ]
        ))
        #expect(recalled.ok == true, "verbose recall failed: \(recalled.error ?? "nil")")
        let hits = try requireHits(try requireObject(recalled.payload))
        let hit = try #require(hits.first { object in
            (object["text"]?.stringValue ?? "").contains(token)
        })
        let explanations = try #require(hit["explanations"]?.arrayValue)
        #expect(explanations.isEmpty == false)
        let metadata = try #require(hit["metadata"]?.objectValue)
        #expect(metadata["wax.content.hash"]?.stringValue?.isEmpty == false)
        #expect(try requireString(hit, "id").hasPrefix("durable:"))
    }
}

@Test
func compactRecallWiresScopeDroppedForLouderForeignHitWithoutAutoWiden() async throws {
    try await withAgentDXRecallBroker { service, _ in
        let token = "WAXDXDROP-\(UUID().uuidString.prefix(8))"
        let home = "Swarmy-\(UUID().uuidString.prefix(8))"
        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("\(token) swarmy operator note."),
                "memory_type": .string("note"),
                "project": .string(home),
                "repo": .string(home),
            ]
        ))).ok == true)
        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("\(token) wax operator lessons wax operator lessons wax operator lessons."),
                "memory_type": .string("decision"),
                "project": .string("Wax"),
                "repo": .string("Wax"),
            ]
        ))).ok == true)

        let recalled = await service.handle(.init(
            command: "recall",
            arguments: [
                "query": .string("\(token) wax operator lessons"),
                "project": .string(home),
                "scope": .string("project"),
                "mode": .string("text"),
                "limit": .int(5),
            ]
        ))
        #expect(recalled.ok == true, "recall failed: \(recalled.error ?? "nil")")
        let payload = try requireObject(recalled.payload)
        let hits = try requireHits(payload)
        #expect(hits.isEmpty == false)
        #expect(hits.allSatisfy { $0["project"]?.stringValue == home })
        #expect(hits.contains { ($0["text"]?.stringValue ?? "").contains("wax operator lessons") } == false)

        let dropped = try requireObject(payload["scope_dropped"])
        #expect((dropped["count"]?.intValue ?? 0) >= 1)
        let top = try #require(dropped["top"]?.arrayValue)
        #expect(top.contains { entry in
            entry.objectValue?["project"]?.stringValue == "Wax"
        })
        #expect((dropped["hint"]?.stringValue ?? "").contains("do not auto-widen"))
        #expect(payload["project_miss"]?.boolValue == false)
    }
}

@Test
func corpusSearchTopThreeIncludeTextAndTheRestKeepPreview() async throws {
    try await withAgentDXRecallBroker { service, _ in
        let token = "WAXDXCORPUS-\(UUID().uuidString.prefix(8))"
        let project = "dx-corpus-\(UUID().uuidString.prefix(8))"
        for index in 1...5 {
            let marker = "DOC-\(index)"
            #expect((await service.handle(.init(
                command: "remember",
                arguments: [
                    "content": .string(paddedCorpusBody(token: token, marker: marker)),
                    "memory_type": .string("note"),
                    "project": .string(project),
                ]
            ))).ok == true)
        }

        let searched = await service.handle(.init(
            command: "corpus_search",
            arguments: [
                "query": .string(token),
                "mode": .string("text"),
                "topK": .int(5),
            ]
        ))
        #expect(searched.ok == true, "corpus_search failed: \(searched.error ?? "nil")")
        let hits = try requireHits(try requireObject(searched.payload))
        #expect(hits.count == 5)
        for (index, hit) in hits.enumerated() {
            if index < 3 {
                let text = try requireString(hit, "text")
                #expect(text.contains(token))
                #expect(text.utf8.count > 512)
            } else {
                #expect(hit["text"] == nil)
                let preview = try requireString(hit, "preview")
                #expect(preview.contains(token))
                #expect(preview.utf8.count <= 512)
            }
        }
    }
}

@Test
func corpusSearchExpandFillsAllHitsWithText() async throws {
    try await withAgentDXRecallBroker { service, _ in
        let token = "WAXDXEXPAND-\(UUID().uuidString.prefix(8))"
        let project = "dx-expand-\(UUID().uuidString.prefix(8))"
        for index in 1...5 {
            #expect((await service.handle(.init(
                command: "remember",
                arguments: [
                    "content": .string(paddedCorpusBody(token: token, marker: "DOC-\(index)")),
                    "memory_type": .string("note"),
                    "project": .string(project),
                ]
            ))).ok == true)
        }

        let searched = await service.handle(.init(
            command: "corpus_search",
            arguments: [
                "query": .string(token),
                "mode": .string("text"),
                "topK": .int(5),
                "expand": .bool(true),
            ]
        ))
        #expect(searched.ok == true, "corpus_search expand failed: \(searched.error ?? "nil")")
        let hits = try requireHits(try requireObject(searched.payload))
        #expect(hits.count == 5)
        for hit in hits {
            let text = try requireString(hit, "text")
            #expect(text.contains(token))
            #expect(text.utf8.count > 512)
        }
    }
}

@Test
func memoryHealthListsUnsupersededDuplicateDecisions() async throws {
    try await withAgentDXRecallBroker { service, _ in
        let project = "dx-health-\(UUID().uuidString.prefix(8))"
        let left = "Prefer project-scoped recall; never auto-widen an empty project lane."
        let right = "Prefer project-scoped recall; never auto-widen an empty project lane now."
        try #require(MemorySemantics.similarity(lhs: left, rhs: right) >= 0.88)
        for text in [left, right] {
            try await service.longTermMemory.remember(
                text,
                metadata: [
                    MemoryMetadataKeys.type: MemoryType.decision.rawValue,
                    MemoryMetadataKeys.durability: MemoryDurability.durable.rawValue,
                    MemoryMetadataKeys.project: project,
                    MemoryMetadataKeys.repo: project,
                ]
            )
        }
        try await service.longTermMemory.flush()

        let health = await service.handle(.init(command: "memory_health"))
        #expect(health.ok == true, "memory_health failed: \(health.error ?? "nil")")
        let payload = try #require(health.payload?.objectValue, "memory_health payload missing")
        let pairs = try #require(payload["unsuperseded_duplicate_decisions"]?.arrayValue)
        #expect(pairs.isEmpty == false)
        let pair = try #require(pairs.first?.objectValue)
        #expect(pair["left_frame_id"]?.intValue != nil)
        #expect(pair["right_frame_id"]?.intValue != nil)
        #expect((pair["similarity"]?.doubleValue ?? 0) >= 0.88)
    }
}

@Test
func compactContextHitsShareSlimShapeWithoutExplanationsOrHashes() async throws {
    try await withAgentDXRecallBroker { service, _ in
        let project = "dx-compact-\(UUID().uuidString.prefix(8))"
        let token = "WAXDXCOMPACT-\(UUID().uuidString.prefix(8))"
        let opened = await service.handle(.init(
            command: "session_open",
            arguments: [
                "project": .string(project),
                "agent_id": .string("dx-compact-agent"),
                "run_id": .string("dx-compact-run"),
            ]
        ))
        #expect(opened.ok == true, "session_open failed: \(opened.error ?? "nil")")
        let sessionID = try requireString(try requireObject(opened.payload), "session_id")
        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Working note \(token) for compact context slim hits."),
                "memory_type": .string("note"),
                "session_id": .string(sessionID),
                "project": .string(project),
            ]
        ))).ok == true)

        let compacted = await service.handle(.init(
            command: "compact_context",
            arguments: [
                "query": .string(token),
                "session_id": .string(sessionID),
                "mode": .string("text"),
                "max_items": .int(6),
                "token_budget": .int(512),
            ]
        ))
        #expect(compacted.ok == true, "compact_context failed: \(compacted.error ?? "nil")")
        let payload = try requireObject(compacted.payload)
        let short = try #require(payload["short_context"]?.arrayValue)
        let hit = try #require(short.first?.objectValue)
        let id = try requireString(hit, "id")
        #expect(id.hasPrefix("working:"))
        #expect((hit["text"]?.stringValue ?? hit["preview"]?.stringValue ?? "").contains(token))
        #expect(try requireString(hit, "project") == project)
        #expect(hit["memory_type"]?.stringValue == "note")
        #expect(hit["age_days"]?.intValue == 0)
        #expect(hit["score"]?.doubleValue != nil)
        #expect(hit["explanations"] == nil)
        #expect(containsContentHash(.object(hit)) == false)
    }
}

@Test
func rememberDurableDecisionWithSessionIDStampsSessionProject() async throws {
    try await withAgentDXRecallBroker { service, _ in
        let project = "dx-stamp-\(UUID().uuidString.prefix(8))"
        let token = "WAXDXSTAMP-\(UUID().uuidString.prefix(8))"
        let opened = await service.handle(.init(
            command: "session_open",
            arguments: [
                "project": .string(project),
                "repo": .string(project),
                "agent_id": .string("dx-stamp-agent"),
                "run_id": .string("dx-stamp-run"),
            ]
        ))
        #expect(opened.ok == true, "session_open failed: \(opened.error ?? "nil")")
        let sessionID = try requireString(try requireObject(opened.payload), "session_id")

        let remembered = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Decision: \(token) stamps session project on a durable type-first write."),
                "session_id": .string(sessionID),
                "memory_type": .string("decision"),
            ]
        ))
        #expect(remembered.ok == true, "remember failed: \(remembered.error ?? "nil")")
        let payload = try requireObject(remembered.payload)
        #expect(payload["scope"]?.stringValue == "durable")
        #expect(payload["session_id"]?.stringValue == nil)
        let frameID = UInt64(try #require(payload["frame_id"]?.intValue))

        let documents = try await service.longTermMemory.corpusSourceDocuments()
        let document = try #require(documents.first { $0.frameId == frameID })
        #expect(document.metadata[MemoryMetadataKeys.project] == project)
        #expect(document.metadata[MemoryMetadataKeys.repo] == project)
        #expect(document.metadata[MemoryMetadataKeys.type] == MemoryType.decision.rawValue)
        #expect(document.metadata[MemoryMetadataKeys.durability] == MemoryDurability.durable.rawValue)
    }
}
#endif

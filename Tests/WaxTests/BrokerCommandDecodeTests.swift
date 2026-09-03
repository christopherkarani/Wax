import Foundation
import Testing
@testable import Wax

struct BrokerCommandDecodeTests {
    @Test
    func rememberAliasCanonicalizesToOneTypedCommand() throws {
        let args: [String: AgentBrokerValue] = [
            "content": .string("  keep spaces  "),
            "session_id": .string("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
            "scope": .string("session"),
            "memory_type": .string("decision"),
            "durability": .string("working"),
        ]
        let remember = try BrokerCommand.decode(command: "remember", arguments: args)
        let append = try BrokerCommand.decode(command: "memory_append", arguments: args)
        guard case .remember(let a) = remember, case .remember(let b) = append else {
            Issue.record("alias mismatch")
            return
        }
        #expect(a == b)
        #expect(a.content == "  keep spaces  ")
        #expect(a.sessionID == UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        #expect(a.writeScope == .session)
        #expect(a.writeSemantics.type == .decision)
    }

    @Test
    func commandCatalogNormalizesAliasesAndStaticFacts() throws {
        #expect(AgentBrokerCommandSurface.canonicalCommand(for: "  MEMORY_APPEND ") == "remember")
        #expect(AgentBrokerCommandSurface.canonicalCommand(for: "QUIT") == "shutdown")
        #expect(AgentBrokerCommandSurface.canonicalCommand(for: "wax_recall") == nil)
        #expect(AgentBrokerCommandSurface.isPublicCommand("memory_append"))
        #expect(!AgentBrokerCommandSurface.isPublicCommand("flush"))
        #expect(!AgentBrokerCommandSurface.isPublicCommand("memory_maintain"))
        #expect(AgentBrokerCommandSurface.requiresStructuredMemory("facts_query"))
        #expect(!AgentBrokerCommandSurface.requiresStructuredMemory("recall"))

        let rememberKeys = try #require(AgentBrokerCommandSurface.allowedArguments(for: "remember"))
        let appendKeys = try #require(AgentBrokerCommandSurface.allowedArguments(for: "memory_append"))
        #expect(rememberKeys == appendKeys)
    }

    @Test
    func rememberRejectsUnknownArgument() {
        #expect(throws: BrokerValidationError.self) {
            _ = try BrokerCommand.decode(
                command: "remember",
                arguments: [
                    "content": .string("x"),
                    "unexpected": .string("y"),
                ]
            )
        }
    }

    @Test
    func rememberScopeSessionRequiresSessionID() {
        #expect(throws: BrokerValidationError.self) {
            _ = try BrokerCommand.decode(
                command: "remember",
                arguments: [
                    "content": .string("x"),
                    "scope": .string("session"),
                ]
            )
        }
    }

    @Test
    func rememberDecisionWithSessionIDLandsDurable() throws {
        let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let decoded = try BrokerCommand.decode(
            command: "remember",
            arguments: [
                "content": .string("type-first decision"),
                "session_id": .string(sessionID.uuidString),
                "memory_type": .string("decision"),
            ]
        )
        guard case .remember(let remember) = decoded else {
            Issue.record("expected remember")
            return
        }
        guard case .durable(let write) = remember.destination else {
            Issue.record("expected durable destination")
            return
        }
        #expect(write.type == .decision)
        #expect(write.durability == .durable)
        #expect(remember.sessionID == nil)
        #expect(remember.writeScope == .durable)
        #expect(remember.writeSemantics.type == .decision)
        #expect(remember.writeSemantics.durability == .durable)
    }

    @Test
    func recallDefaultsAndModeRules() throws {
        let decoded = try BrokerCommand.decode(
            command: "recall",
            arguments: ["query": .string("what happened")]
        )
        guard case .recall(let payload) = decoded else {
            Issue.record("expected recall")
            return
        }
        #expect(payload.query == "what happened")
        #expect(payload.limit == 5)
        #expect(payload.searchTopK == 5)
        #expect(payload.scope == .project)
        #expect(payload.mode == nil)
    }

    @Test
    func recallRejectsAlphaUnlessHybrid() {
        #expect(throws: BrokerValidationError.self) {
            _ = try BrokerCommand.decode(
                command: "recall",
                arguments: [
                    "query": .string("q"),
                    "mode": .string("text"),
                    "alpha": .double(0.2),
                ]
            )
        }
    }

    @Test
    func recallAcceptsHybridAlpha() throws {
        let decoded = try BrokerCommand.decode(
            command: "recall",
            arguments: [
                "query": .string("q"),
                "mode": .string("hybrid"),
                "alpha": .double(0.25),
                "search_top_k": .int(7),
                "limit": .int(3),
            ]
        )
        guard case .recall(let payload) = decoded else {
            Issue.record("expected recall")
            return
        }
        #expect(payload.mode == .hybrid(alpha: 0.25))
        #expect(payload.limit == 3)
        #expect(payload.searchTopK == 7)
    }

    @Test
    func searchDefaultsModeToText() throws {
        let decoded = try BrokerCommand.decode(
            command: "search",
            arguments: ["query": .string("needle")]
        )
        guard case .search(let payload) = decoded else {
            Issue.record("expected search")
            return
        }
        #expect(payload.mode == .textOnly)
        #expect(payload.topK == 10)
    }

    @Test
    func hybridWithoutAlphaUsesCanonicalDefault() throws {
        let recall = try BrokerCommand.decode(
            command: "recall",
            arguments: [
                "query": .string("q"),
                "mode": .string("hybrid"),
            ]
        )
        guard case .recall(let recallPayload) = recall else {
            Issue.record("expected recall")
            return
        }
        #expect(recallPayload.mode == .hybrid(alpha: 0.5))

        let search = try BrokerCommand.decode(
            command: "search",
            arguments: [
                "query": .string("q"),
                "mode": .string("HYBRID"),
            ]
        )
        guard case .search(let searchPayload) = search else {
            Issue.record("expected search")
            return
        }
        #expect(searchPayload.mode == .hybrid(alpha: 0.5))
        #expect(searchPayload.mode.diagnosticsSummary == "hybrid(alpha=0.500)")
    }

    @Test
    func memorySearchIsDistinctFromSearch() throws {
        let decoded = try BrokerCommand.decode(
            command: "memory_search",
            arguments: [
                "query": .string("needle"),
                "include_working": .bool(false),
                "include_episodic": .bool(false),
                "include_durable": .bool(true),
            ]
        )
        guard case .memorySearch(let payload) = decoded else {
            Issue.record("expected memory_search")
            return
        }
        #expect(payload.horizons == [.durable])
        #expect(payload.mode == .textOnly)
    }

    @Test
    func memorySearchDefaultsToAllLanes() throws {
        let decoded = try BrokerCommand.decode(
            command: "memory_search",
            arguments: ["query": .string("needle")]
        )
        guard case .memorySearch(let payload) = decoded else {
            Issue.record("expected memory_search")
            return
        }
        #expect(payload.horizons == HorizonSet.all)
    }

    @Test
    func memorySearchMapsIndividualLaneFlags() throws {
        let workingOnly = try BrokerCommand.decode(
            command: "memory_search",
            arguments: ["query": .string("q"), "include_episodic": .bool(false), "include_durable": .bool(false)]
        )
        guard case .memorySearch(let payload) = workingOnly else {
            Issue.record("expected memory_search")
            return
        }
        #expect(payload.horizons == [.working])
    }

    @Test
    func memorySearchRejectsEmptyLaneSelection() throws {
        var thrownMessage: String?
        do {
            _ = try BrokerCommand.decode(
                command: "memory_search",
                arguments: [
                    "query": .string("needle"),
                    "include_working": .bool(false),
                    "include_episodic": .bool(false),
                    "include_durable": .bool(false),
                ]
            )
        } catch let error as BrokerValidationError {
            thrownMessage = error.errorDescription ?? String(describing: error)
        }
        let message = try #require(thrownMessage, "empty lane selection must be rejected at decode")
        #expect(message.lowercased().contains("lane"))
    }

    @Test
    func sessionAndHandoffDecode() throws {
        let start = try BrokerCommand.decode(
            command: "session_start",
            arguments: [
                "agent_id": .string("agent"),
                "run_id": .string("run"),
            ]
        )
        guard case .sessionStart(let startPayload) = start else {
            Issue.record("expected session_start")
            return
        }
        #expect(startPayload.agentID == "agent")
        #expect(startPayload.runID == "run")

        let handoff = try BrokerCommand.decode(
            command: "handoff",
            arguments: [
                "content": .string("summary"),
                "pending_tasks": .array([.string("one"), .string("two")]),
            ]
        )
        guard case .handoff(let handoffPayload) = handoff else {
            Issue.record("expected handoff")
            return
        }
        #expect(handoffPayload.content == "summary")
        #expect(handoffPayload.pendingTasks == ["one", "two"])

        let latest = try BrokerCommand.decode(
            command: "handoff_latest",
            arguments: ["project": .string("Wax")]
        )
        guard case .handoffLatest(let latestPayload) = latest else {
            Issue.record("expected handoff_latest")
            return
        }
        #expect(latestPayload.project == "Wax")
    }

    @Test
    func stage2aEmptyArgCommandsDecode() throws {
        #expect(try BrokerCommand.decode(command: "flush", arguments: [:]) == .flush)
        #expect(try BrokerCommand.decode(command: "memory_health", arguments: [:]) == .memoryHealth)
        #expect(try BrokerCommand.decode(command: "shutdown", arguments: [:]) == .shutdown)
        #expect(try BrokerCommand.decode(command: "exit", arguments: [:]) == .shutdown)
        #expect(try BrokerCommand.decode(command: "quit", arguments: [:]) == .shutdown)
    }

    @Test
    func stage2aStatsAndMemoryGetDecode() throws {
        let stats = try BrokerCommand.decode(
            command: "stats",
            arguments: ["session_id": .string("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")]
        )
        guard case .stats(let payload) = stats else {
            Issue.record("expected stats")
            return
        }
        #expect(payload.sessionID == UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))

        let get = try BrokerCommand.decode(
            command: "memory_get",
            arguments: ["memory_id": .string("durable:42")]
        )
        guard case .memoryGet(let memoryGet) = get else {
            Issue.record("expected memory_get")
            return
        }
        #expect(memoryGet.memoryID == "durable:42")
    }

    @Test
    func stage2aGraphAndMarkdownSyncDecode() throws {
        let upsert = try BrokerCommand.decode(
            command: "entity_upsert",
            arguments: [
                "key": .string("project:wax"),
                "kind": .string("project"),
                "aliases": .array([.string("Wax")]),
            ]
        )
        guard case .entityUpsert(let entity) = upsert else {
            Issue.record("expected entity_upsert")
            return
        }
        #expect(entity.key == "project:wax")
        #expect(entity.aliases == ["Wax"])

        let resolve = try BrokerCommand.decode(
            command: "entity_resolve",
            arguments: ["alias": .string("Wax")]
        )
        guard case .entityResolve(let match) = resolve else {
            Issue.record("expected entity_resolve")
            return
        }
        #expect(match.alias == "Wax")
        #expect(match.limit == 10)

        let retract = try BrokerCommand.decode(
            command: "fact_retract",
            arguments: ["fact_id": .int(9), "at_ms": .int(100)]
        )
        guard case .factRetract(let fact) = retract else {
            Issue.record("expected fact_retract")
            return
        }
        #expect(fact.factID == 9)
        #expect(fact.atMs == 100)

        let sync = try BrokerCommand.decode(
            command: "markdown_sync",
            arguments: ["root_dir": .string("/tmp/proj"), "dry_run": .bool(true)]
        )
        guard case .markdownSync(let markdown) = sync else {
            Issue.record("expected markdown_sync")
            return
        }
        #expect(markdown.rootDir == "/tmp/proj")
        #expect(markdown.dryRun)
    }

    @Test
    func stage2bSessionCloseOpenAndFactsQueryDecode() throws {
        let close = try BrokerCommand.decode(
            command: "session_close",
            arguments: [
                "session_id": .string("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
                "content": .string("done"),
            ]
        )
        guard case .sessionClose(let payload) = close else {
            Issue.record("expected session_close")
            return
        }
        #expect(payload.content == "done")

        let open = try BrokerCommand.decode(
            command: "session_open",
            arguments: ["project": .string("wax"), "recall_query": .string("prior work")]
        )
        guard case .sessionOpen(let opened) = open else {
            Issue.record("expected session_open")
            return
        }
        #expect(opened.project == "wax")
        #expect(opened.recallQuery == "prior work")

        let blankOpen = try BrokerCommand.decode(
            command: "session_open",
            arguments: [
                "project": .string("   "),
                "repo": .string(""),
            ]
        )
        guard case .sessionOpen(let blank) = blankOpen else {
            Issue.record("expected session_open")
            return
        }
        #expect(blank.project == nil)
        #expect(blank.repo == nil)

        let facts = try BrokerCommand.decode(
            command: "facts_query",
            arguments: ["subject": .string("project:wax"), "limit": .int(5)]
        )
        guard case .factsQuery(let query) = facts else {
            Issue.record("expected facts_query")
            return
        }
        #expect(query.subject == "project:wax")
        #expect(query.limit == 5)
    }

    @Test
    func stage2bCompactContextAndKnowledgeCaptureDecode() throws {
        let compact = try BrokerCommand.decode(
            command: "compact_context",
            arguments: ["query": .string("summarize"), "token_budget": .int(512)]
        )
        guard case .compactContext(let payload) = compact else {
            Issue.record("expected compact_context")
            return
        }
        #expect(payload.query == "summarize")
        #expect(payload.tokenBudget == 512)
        #expect(payload.mode == .textOnly)

        let capture = try BrokerCommand.decode(
            command: "knowledge_capture",
            arguments: [
                "content": .string("Wax owns broker memory"),
                "subject": .string("project:wax"),
                "predicate": .string("owns"),
                "object": .string("broker memory"),
            ]
        )
        guard case .knowledgeCapture(let knowledge) = capture else {
            Issue.record("expected knowledge_capture")
            return
        }
        #expect(knowledge.writeSemantics.durability == .durable)
        #expect(knowledge.object == .string("broker memory"))

        let exported = try BrokerCommand.decode(
            command: "markdown_export",
            arguments: ["output_dir": .string("/tmp/wax-md")]
        )
        guard case .markdownExport(let markdown) = exported else {
            Issue.record("expected markdown_export")
            return
        }
        #expect(markdown.outputDir == "/tmp/wax-md")
        #expect(markdown.allProjects == false)

        let synthesize = try BrokerCommand.decode(
            command: "session_synthesize",
            arguments: ["max_candidates": .int(3)]
        )
        guard case .sessionSynthesize(let settings) = synthesize else {
            Issue.record("expected session_synthesize")
            return
        }
        #expect(settings.maxCandidates == 3)

        #expect(throws: BrokerValidationError.self) {
            _ = try BrokerCommand.decode(
                command: "session_close",
                arguments: ["content": .string("done")]
            )
        }
    }

    @Test
    func stage2cPromoteFactAssertAndCorpusDecode() throws {
        let promote = try BrokerCommand.decode(command: "promote", arguments: [
            "content": .string("ship it"),
        ])
        guard case .promote(let payload) = promote else {
            Issue.record("expected promote")
            return
        }
        #expect(payload.approve)
        #expect(payload.content == "ship it")

        let memoryPromote = try BrokerCommand.decode(command: "memory_promote", arguments: [
            "content": .string("review only"),
        ])
        guard case .memoryPromote(let review) = memoryPromote else {
            Issue.record("expected memory_promote")
            return
        }
        #expect(!review.approve)

        let assert = try BrokerCommand.decode(
            command: "fact_assert",
            arguments: [
                "subject": .string("project:wax"),
                "predicate": .string("owns"),
                "object": .string("broker memory"),
                "relation": .string("sets"),
            ]
        )
        guard case .factAssert(let fact) = assert else {
            Issue.record("expected fact_assert")
            return
        }
        #expect(fact.subject == "project:wax")
        #expect(fact.object == .string("broker memory"))
        #expect(fact.relation == "sets")

        let corpus = try BrokerCommand.decode(
            command: "corpus_search",
            arguments: ["query": .string("hello"), "topK": .int(3)]
        )
        guard case .corpusSearch(let search) = corpus else {
            Issue.record("expected corpus_search")
            return
        }
        #expect(search.query == "hello")
        #expect(search.topK == 3)
        #expect(search.mode == .textOnly)
    }

    @Test
    func factAssertRequiresObject() {
        #expect(throws: BrokerValidationError.self) {
            _ = try BrokerCommand.decode(
                command: "fact_assert",
                arguments: [
                    "subject": .string("project:wax"),
                    "predicate": .string("owns"),
                ]
            )
        }
    }

    @Test
    func corpusSearchRejectsOutOfRangeTopK() {
        #expect(throws: BrokerValidationError.self) {
            _ = try BrokerCommand.decode(
                command: "corpus_search",
                arguments: ["query": .string("hello"), "topK": .int(0)]
            )
        }
    }

    @Test
    func everyRegisteredCommandHasTypedDecode() {
        for command in AgentBrokerCommandSurface.commandArguments.keys.sorted() {
            do {
                _ = try BrokerCommand.decode(command: command, arguments: [:])
            } catch let error as BrokerValidationError {
                let message = error.errorDescription ?? String(describing: error)
                #expect(
                    !message.contains("Unknown broker command"),
                    "\(command) fell through to unknown instead of a typed payload"
                )
            } catch {
                Issue.record("\(command) threw unexpected error \(error)")
            }
        }
    }

    @Test
    func memoryMaintainDefaultsToDryRunAndHonorsDryRunOverride() throws {
        let dry = try BrokerCommand.decode(command: "memory_maintain", arguments: [:])
        guard case .memoryMaintain(let payload) = dry else {
            Issue.record("expected memory_maintain")
            return
        }
        #expect(payload.apply == false)
        #expect(payload.forceReclaim == false)

        let forcedDry = try BrokerCommand.decode(
            command: "memory_maintain",
            arguments: [
                "apply": .bool(true),
                "dry_run": .bool(true),
                "force_reclaim": .bool(true),
            ]
        )
        guard case .memoryMaintain(let overridden) = forcedDry else {
            Issue.record("expected memory_maintain override")
            return
        }
        #expect(overridden.apply == false)
        #expect(overridden.forceReclaim == true)
    }

    @Test
    func unknownCommandRejectedAtDecode() {
        #expect(throws: BrokerValidationError.self) {
            _ = try BrokerCommand.decode(command: "not_a_real_command", arguments: [:])
        }
    }

    @Test
    func emptyRecallQueryRejected() {
        #expect(throws: BrokerValidationError.self) {
            _ = try BrokerCommand.decode(
                command: "recall",
                arguments: ["query": .string("   ")]
            )
        }
    }

    @Test
    func entityResolveRejectsOutOfRangeLimit() {
        #expect(throws: BrokerValidationError.self) {
            _ = try BrokerCommand.decode(
                command: "entity_resolve",
                arguments: ["alias": .string("Wax"), "limit": .int(0)]
            )
        }
        #expect(throws: BrokerValidationError.self) {
            _ = try BrokerCommand.decode(
                command: "entity_resolve",
                arguments: [
                    "alias": .string("Wax"),
                    "limit": .int(Int64(BrokerLimits.maxEntityResolveLimit) + 1),
                ]
            )
        }
    }
}

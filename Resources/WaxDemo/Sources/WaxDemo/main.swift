import Foundation
import Wax

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - CLI

private enum Mode: String, CaseIterable {
    case memory
    case framestore
    case embeddings
    case fm
    case errors
    case all
}

private struct DemoOptions {
    var mode: Mode = .all
    var storePath: URL?
    var keepFile = false
    var runID = "1"
}

private enum DemoError: Error, CustomStringConvertible {
    case usage(String)
    case assertion(String)

    var description: String {
        switch self {
        case .usage(let message), .assertion(let message):
            return message
        }
    }

    var isUsage: Bool {
        if case .usage = self { return true }
        return false
    }
}

private func usage() -> String {
    """
    WaxDemo — real consumer stress harness for public Wax APIs

    Usage:
      swift run WaxDemo [--mode memory|framestore|embeddings|fm|errors|all] [--store PATH] [--keep] [--run-id N]

    Modes:
      memory      Durable save → search → close → reopen → search (content assertions)
      framestore  FrameStore create/put/read/delete round-trip
      embeddings  BuiltInEmbeddings MiniLM + hybrid/vector search
      fm          Foundation Models memory-grounded multi-turn (or honest unavailability)
      errors      WaxError / validation failure paths
      all         Run every mode (default)
    """
}

private func parseArgs(_ args: [String]) throws -> DemoOptions {
    var options = DemoOptions()
    var index = 0
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--help", "-h":
            throw DemoError.usage(usage())
        case "--keep":
            options.keepFile = true
        case "--mode":
            index += 1
            guard index < args.count, let mode = Mode(rawValue: args[index]) else {
                throw DemoError.usage("--mode requires memory|framestore|embeddings|fm|errors|all")
            }
            options.mode = mode
        case "--store":
            index += 1
            guard index < args.count else {
                throw DemoError.usage("--store requires a path")
            }
            options.storePath = URL(fileURLWithPath: args[index])
        case "--run-id":
            index += 1
            guard index < args.count else {
                throw DemoError.usage("--run-id requires a value")
            }
            options.runID = args[index]
        default:
            throw DemoError.usage("Unknown arg: \(arg)\n\n\(usage())")
        }
        index += 1
    }
    return options
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw DemoError.assertion(message)
    }
}

private func containsFact(_ haystack: String, _ needle: String) -> Bool {
    haystack.localizedCaseInsensitiveContains(needle)
}

// MARK: - Strategies / Rerankers (exercise public protocols)

private struct TextOnlyStrategy: SearchStrategy {
    func configure(_ options: inout Memory.SearchOptions) {
        options.mode = .textOnly
        options.topK = 5
    }
}

private struct IdentityReranker: ResultReranker {
    func rerank(query: String, results: Memory.Results) async throws -> Memory.Results {
        Memory.Results(query: query, items: results.items, totalTokens: results.totalTokens)
    }
}

// MARK: - Memory durable path

private func runMemory(storeURL: URL, runID: String) async throws {
    print("=== MODE memory (run \(runID)) ===")
    print("STORE \(storeURL.path)")

    let uniqueToken = "WAX_STRESS_TOKEN_\(runID)_\(UUID().uuidString.prefix(8))"
    let factA = "The user's preferred editor is Helix for \(uniqueToken)."
    let factB = "Deploy target is macOS only for project \(uniqueToken)."

    // First open: save + search + flush + close
    do {
        let memory = try await Memory(at: storeURL) { config in
            config.enableVectorSearch = false
            config.enableTextSearch = true
            config.requireOnDeviceProviders = false
        }

        try await memory.save(factA, metadata: ["surface": "memory", "run": runID])
        try await memory.save(factB)
        try await memory.save("Secondary note about \(uniqueToken) pipeline.")

        let textHits = try await memory.search("preferred editor Helix") { options in
            options.topK = 5
            options.mode = .textOnly
        }
        try require(!textHits.items.isEmpty, "memory search returned empty after save")
        let joined = textHits.items.map(\.text).joined(separator: "\n")
        try require(containsFact(joined, "Helix"), "expected Helix in search hits, got: \(joined)")
        try require(containsFact(joined, uniqueToken), "expected unique token in search hits")
        print("SEARCH_HIT \(textHits.items.first?.text.prefix(120) ?? "")")
        print("RAG_QUERY \(textHits.query)")
        print("RAG_TOKENS \(textHits.totalTokens)")
        if let first = textHits.items.first {
            print("RAG_SOURCES \(first.sources.map(\.rawValue).joined(separator: ","))")
            print("RAG_KIND \(String(describing: first.kind))")
        }

        let strategyHits = try await memory.search(
            "deploy target macOS",
            strategy: TextOnlyStrategy(),
            options: .default,
            reranker: IdentityReranker()
        )
        try require(
            strategyHits.items.contains(where: { containsFact($0.text, "macOS") || containsFact($0.text, uniqueToken) }),
            "strategy/reranker search missed deploy fact"
        )
        print("STRATEGY_HIT_COUNT \(strategyHits.items.count)")

        try await memory.flush()
        try await memory.close()
        print("PHASE1_OK saved+searched+flushed+closed")
    }

    // Reopen: durable recall must still find facts
    do {
        let memory = try await Memory(at: storeURL, config: Memory.Config(
            enableTextSearch: true,
            enableVectorSearch: false,
            requireOnDeviceProviders: false
        ))

        let reopenHits = try await memory.search(
            uniqueToken,
            options: Memory.SearchOptions(topK: 10, mode: .textOnly)
        )
        try require(!reopenHits.items.isEmpty, "reopen search returned empty — durability failed")
        let joined = reopenHits.items.map(\.text).joined(separator: "\n")
        try require(containsFact(joined, "Helix"), "durable reopen missed Helix fact: \(joined)")
        try require(containsFact(joined, uniqueToken), "durable reopen missed unique token: \(joined)")
        try require(containsFact(joined, "macOS"), "durable reopen missed macOS fact: \(joined)")
        print("REOPEN_HIT_COUNT \(reopenHits.items.count)")
        print("REOPEN_CONTENT_OK \(uniqueToken)")
        try await memory.close()
        print("PHASE2_OK reopen+durable_recall")
    }

    let scope = MemoryScopeContext(
        cwdPath: FileManager.default.currentDirectoryPath,
        repoRootPath: nil,
        repoName: "Wax",
        projectName: "WaxDemo"
    )
    print("SEMANTICS type=\(MemoryType.fact.rawValue) durability=\(MemoryDurability.durable.rawValue) project=\(scope.projectName ?? "")")
    print("MEMORY_OK")
}

// MARK: - FrameStore

private func runFrameStore(storeURL: URL) async throws {
    print("=== MODE framestore ===")
    print("STORE \(storeURL.path)")

    let payloadText = "FrameStore stress payload \(UUID().uuidString)"
    let payload = Data(payloadText.utf8)

    // Use a modest WAL so stress runs stay light; production default is 256 MiB.
    let store = try await FrameStore.create(at: storeURL, walSize: 4 * 1024 * 1024)
    let frameID = try await store.put(payload, kind: "note", metadata: ["demo": "framestore"])
    print("PUT_ID \(frameID)")

    let frames = try await store.frames()
    try require(frames.contains(where: { $0.id == frameID && $0.status == .active }), "put frame missing from frames()")
    let content = try await store.content(frameID: frameID)
    let decoded = String(data: content, encoding: .utf8) ?? ""
    try require(decoded == payloadText, "content round-trip mismatch: \(decoded)")
    print("CONTENT_OK \(decoded.prefix(60))")

    try await store.delete(frameID: frameID)
    let afterDelete = try await store.frames()
    if let deleted = afterDelete.first(where: { $0.id == frameID }) {
        try require(deleted.status == .deleted, "expected deleted status, got \(deleted.status)")
        print("DELETE_STATUS deleted")
    } else {
        do {
            _ = try await store.content(frameID: frameID)
            throw DemoError.assertion("deleted frame still readable")
        } catch is DemoError {
            throw DemoError.assertion("deleted frame still readable")
        } catch {
            print("DELETE_STATUS omitted_or_unreadable")
        }
    }

    try await store.close()

    // close() must release the exclusive lock so reopen does not hang.
    let reopened = try await FrameStore.open(at: storeURL)
    let reopenedFrames = try await reopened.frames()
    print("REOPEN_FRAME_COUNT \(reopenedFrames.count)")
    try await reopened.close()
    print("FRAMESTORE_OK")
}

// MARK: - BuiltInEmbeddings + hybrid search

private func runEmbeddings(storeURL: URL) async throws {
    print("=== MODE embeddings ===")
    print("STORE \(storeURL.path)")

    let fact = "Vector fact: the constellation project uses CoreML MiniLM embeddings for hybrid search."
    let memory = try await Memory(
        at: storeURL,
        config: Memory.Config(enableVectorSearch: true, requireOnDeviceProviders: true),
        builtInEmbedding: .miniLM
    )

    try await memory.save(fact, metadata: ["surface": "embeddings"])
    try await memory.flush()

    let text = try await memory.search("constellation CoreML", options: .init(topK: 5, mode: .textOnly))
    try require(
        text.items.contains(where: { containsFact($0.text, "MiniLM") || containsFact($0.text, "constellation") }),
        "text search missed embedding fact"
    )
    print("TEXT_HIT_OK")

    let hybrid = try await memory.search(
        "hybrid CoreML embedding constellation",
        options: .init(topK: 5, mode: .hybrid(alpha: 0.4))
    )
    try require(!hybrid.items.isEmpty, "hybrid search returned empty")
    let hybridJoined = hybrid.items.map(\.text).joined(separator: "\n")
    try require(
        containsFact(hybridJoined, "constellation")
            || containsFact(hybridJoined, "MiniLM")
            || containsFact(hybridJoined, "CoreML"),
        "hybrid search content miss: \(hybridJoined)"
    )
    print("HYBRID_HIT \(hybrid.items.first?.text.prefix(100) ?? "")")
    print("HYBRID_SOURCES \(hybrid.items.first?.sources.map(\.rawValue).joined(separator: ",") ?? "")")

    let embedder = try await BuiltInEmbeddings.make(.miniLM)
    print("EMBEDDER_DIMS \(embedder.dimensions) normalize=\(embedder.normalize)")
    let vector = try await embedder.embed("constellation hybrid")
    try require(vector.count == embedder.dimensions, "embedding dim mismatch \(vector.count) vs \(embedder.dimensions)")
    print("EMBED_VECTOR_LEN \(vector.count)")

    try await memory.close()
    print("EMBEDDINGS_OK")
}

// MARK: - Foundation Models

private func runFoundationModels(storeURL: URL, logPath: URL?) async throws {
    print("=== MODE fm ===")
    print("STORE \(storeURL.path)")

    #if canImport(FoundationModels)
    if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
        try await runFoundationModelsAvailable(storeURL: storeURL, logPath: logPath)
        return
    }
    #endif

    let msg = "FoundationModels not importable or OS below macOS 26"
    print("FM_UNAVAILABLE \(msg)")
    if let logPath {
        try msg.write(to: logPath, atomically: true, encoding: .utf8)
    }
    try await runMemoryOnlyFMFallback(storeURL: storeURL)
}

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
private func runFoundationModelsAvailable(storeURL: URL, logPath: URL?) async throws {
    let memory = try await Memory(at: storeURL) { config in
        config.enableVectorSearch = false
        config.requireOnDeviceProviders = false
    }

    let secretFact = "User's favorite onboard color code is cerulean-77 for the Wax stress app."
    try await memory.save(secretFact, metadata: ["surface": "fm"])
    try await memory.flush()

    let toolConfig = WaxMemoryToolConfig(
        recallMaxItems: 5,
        searchTopK: 5,
        embeddingPolicy: .never,
        includeScores: true
    )
    let rememberTool = WaxRememberTool(memory: memory, config: toolConfig)
    let recallTool = WaxRecallTool(memory: memory, config: toolConfig)
    let searchTool = WaxSearchTool(memory: memory, config: toolConfig)
    let combined = WaxMemoryTool(memory: memory, config: toolConfig)

    let toolRemember = try await rememberTool.call(
        arguments: .init(content: "User deploys WaxDemo only on Apple Silicon Macs.")
    )
    try require(toolRemember.isSuccess, "WaxRememberTool failed: \(toolRemember.message)")
    print("TOOL_REMEMBER \(toolRemember.message)")

    let toolRecall = try await recallTool.call(arguments: .init(query: "favorite color code cerulean"))
    try require(toolRecall.isSuccess, "WaxRecallTool failed: \(toolRecall.message)")
    try require(
        toolRecall.message.localizedCaseInsensitiveContains("cerulean")
            || toolRecall.message.localizedCaseInsensitiveContains("77"),
        "recall tool missed cerulean fact: \(toolRecall.message)"
    )
    print("TOOL_RECALL_OK")

    let toolSearch = try await searchTool.call(arguments: .init(query: "Apple Silicon", topK: 3))
    try require(toolSearch.isSuccess, "WaxSearchTool failed: \(toolSearch.message)")
    print("TOOL_SEARCH items=\(toolSearch.itemCount)")

    let combinedResult = await combined.perform(.init(action: "recall", query: "cerulean-77"))
    try require(combinedResult.isSuccess, "combined tool recall failed")
    print("TOOL_COMBINED_OK action=\(combinedResult.action)")

    var sessionConfig = FoundationModelsMemorySessionConfig.default
    sessionConfig.contextStrategy = .hybrid
    sessionConfig.persistencePolicy = .userAndAssistant
    sessionConfig.embeddingPolicy = .never
    sessionConfig.includeMemoryTools = true
    sessionConfig.toolConfig = toolConfig
    sessionConfig.promptBuilder = FoundationModelsMemoryPromptBuilder(maxItems: 4, includeScores: false)

    let model = SystemLanguageModel.default
    print("FM_MODEL_AVAILABILITY \(String(describing: model.availability))")

    switch model.availability {
    case .available:
        let session = memory.foundationModelsSession(
            model: model,
            instructions: "You are a concise assistant. Use memory when answering preferences.",
            configuration: sessionConfig
        )

        let prepared = try await session.preparePrompt(for: "What is my favorite onboard color code?")
        try require(
            prepared.localizedCaseInsensitiveContains("cerulean") || prepared.localizedCaseInsensitiveContains("77"),
            "preparePrompt missing memory context: \(prepared.prefix(400))"
        )
        print("PREPARE_PROMPT_OK len=\(prepared.count)")

        try await session.remember("The stress-test mission code is ORBIT-42.")
        try await session.flush()

        do {
            let answer = try await session.respond(
                to: "What is the stress-test mission code and my favorite color code?"
            )
            print("FM_RESPOND \(answer)")
            let lower = answer.lowercased()
            let hasMission = lower.contains("orbit") || lower.contains("42")
            let hasColor = lower.contains("cerulean") || lower.contains("77")
            try require(hasMission || hasColor, "FM respond did not ground in memory: \(answer)")
            print("FM_GROUNDED mission=\(hasMission) color=\(hasColor)")

            let follow = try await session.respond(to: "Repeat only the mission code.")
            print("FM_FOLLOWUP \(follow)")
            print("FM_TRANSCRIPT_COUNT \(session.transcript.count)")
            print("FM_OK")
        } catch {
            print("FM_RESPOND_ERROR \(error)")
            let recall = try await session.recall(query: "mission code ORBIT")
            try require(
                recall.items.contains(where: { containsFact($0.text, "ORBIT") || containsFact($0.text, "42") }),
                "session.recall missed mission code"
            )
            print("FM_PARTIAL_OK tools+prepare+session_recall")
        }

        try await session.flush()

    case .unavailable(let reason):
        print("FM_UNAVAILABLE \(String(describing: reason))")
        let hits = try await memory.search("cerulean", options: .init(topK: 3, mode: .textOnly))
        try require(
            hits.items.contains(where: { containsFact($0.text, "cerulean") }),
            "memory path failed while FM unavailable"
        )
        print("FM_FALLBACK_MEMORY_OK")
        if let logPath {
            try """
            Foundation Models unavailable: \(String(describing: reason))
            Memory-only path still proved durable recall of cerulean-77.
            """.write(to: logPath, atomically: true, encoding: .utf8)
        }

    @unknown default:
        print("FM_UNAVAILABLE unknown")
        if let logPath {
            try "Foundation Models availability unknown".write(to: logPath, atomically: true, encoding: .utf8)
        }
    }

    try await memory.close()
}
#endif

private func runMemoryOnlyFMFallback(storeURL: URL) async throws {
    let memory = try await Memory(at: storeURL) {
        $0.enableVectorSearch = false
        $0.requireOnDeviceProviders = false
    }
    try await memory.save("FM-fallback fact: cerulean-77 still searchable.")
    try await memory.flush()
    let hits = try await memory.search("cerulean", options: .init(mode: .textOnly))
    try require(!hits.items.isEmpty, "fallback memory empty")
    try await memory.close()
    print("FM_FALLBACK_MEMORY_OK")
}

// MARK: - Error paths

private func runErrors(baseDir: URL) async throws {
    print("=== MODE errors ===")

    let missing = baseDir.appendingPathComponent("does-not-exist-\(UUID().uuidString).wax")
    do {
        _ = try await FrameStore.open(at: missing)
        throw DemoError.assertion("expected FrameStore.open on missing path to fail")
    } catch is DemoError {
        throw DemoError.assertion("expected FrameStore.open on missing path to fail")
    } catch {
        print("ERROR_FRAMESTORE_OPEN \(type(of: error)): \(error)")
    }

    let vectorStore = baseDir.appendingPathComponent("error-vector-\(UUID().uuidString).wax")
    do {
        let memory = try await Memory(at: vectorStore) { config in
            config.enableVectorSearch = false
            config.requireOnDeviceProviders = false
        }
        try await memory.save("plain text only")
        do {
            _ = try await memory.search("plain", options: .init(mode: .vectorOnly))
            try await memory.close()
            throw DemoError.assertion("vectorOnly without embedder should throw")
        } catch is DemoError {
            try await memory.close()
            throw DemoError.assertion("vectorOnly without embedder should throw")
        } catch {
            print("ERROR_VECTOR_ONLY \(type(of: error)): \(error)")
            try await memory.close()
        }
    }

    let emptyStore = baseDir.appendingPathComponent("error-empty-\(UUID().uuidString).wax")
    let memory = try await Memory(at: emptyStore) {
        $0.enableVectorSearch = false
        $0.requireOnDeviceProviders = false
    }
    do {
        try await memory.save("   ")
        print("ERROR_EMPTY_SAVE accepted")
    } catch {
        print("ERROR_EMPTY_SAVE rejected \(error)")
    }
    try await memory.close()
    print("ERRORS_OK")
}

// MARK: - Main

@main
struct WaxDemoMain {
    static func main() async {
        do {
            try await run()
            exit(0)
        } catch let error as DemoError {
            fputs("\(error)\n", stderr)
            exit(error.isUsage ? 64 : 1)
        } catch {
            fputs("FATAL \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        let options = try parseArgs(Array(CommandLine.arguments.dropFirst()))
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-demo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        defer {
            if !options.keepFile {
                try? FileManager.default.removeItem(at: baseDir)
            } else {
                print("KEEP_DIR \(baseDir.path)")
            }
        }

        print("WAX_DEMO_START mode=\(options.mode.rawValue) run=\(options.runID)")

        let modes: [Mode]
        switch options.mode {
        case .all:
            modes = [.memory, .framestore, .embeddings, .fm, .errors]
        default:
            modes = [options.mode]
        }

        for mode in modes {
            switch mode {
            case .memory:
                let url = options.storePath
                    ?? baseDir.appendingPathComponent("memory-\(options.runID).wax")
                try await runMemory(storeURL: url, runID: options.runID)
            case .framestore:
                let url = baseDir.appendingPathComponent("frames.wax")
                try await runFrameStore(storeURL: url)
            case .embeddings:
                let url = baseDir.appendingPathComponent("embeddings.wax")
                try await runEmbeddings(storeURL: url)
            case .fm:
                let url = baseDir.appendingPathComponent("fm.wax")
                let fmLog = baseDir.appendingPathComponent("fm-status.log")
                try await runFoundationModels(storeURL: url, logPath: fmLog)
                if FileManager.default.fileExists(atPath: fmLog.path) {
                    print("FM_LOG \(fmLog.path)")
                    if let text = try? String(contentsOf: fmLog, encoding: .utf8) {
                        print("FM_LOG_BODY \(text.prefix(300))")
                    }
                }
            case .errors:
                try await runErrors(baseDir: baseDir)
            case .all:
                break
            }
        }

        print("WAX_DEMO_ALL_OK mode=\(options.mode.rawValue) run=\(options.runID)")
    }
}

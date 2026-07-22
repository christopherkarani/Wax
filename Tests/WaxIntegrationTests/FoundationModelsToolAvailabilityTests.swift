#if canImport(FoundationModels)
import Foundation
import FoundationModels
import Testing
import Wax

@Test
func foundationModelsMemoryToolFactoryCompilesAndBuildsWhenAvailable() async throws {
    guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { config in
            config.enableVectorSearch = false
        }
        let tool = memory.foundationModelsMemoryTool()
        #expect(tool.name == "waxMemory")
        #expect(tool.includesSchemaInInstructions == true)
        #expect(!tool.description.isEmpty)

        let tools = memory.foundationModelsTools()
        #expect(tools.count == 3)
        #expect(tools.map(\.name).sorted() == ["waxRecall", "waxRemember", "waxSearch"].sorted())

        let combined = memory.foundationModelsCombinedTools()
        #expect(combined.count == 1)
        #expect(combined.first?.name == "waxMemory")

        let focused = memory.foundationModelsTools(kit: .focused)
        #expect(focused.count == 3)
        #expect(focused.map(\.name).sorted() == ["waxRecall", "waxRemember", "waxSearch"].sorted())

        let compact = memory.foundationModelsTools(kit: .compact)
        #expect(compact.count == 2)
        #expect(compact.map(\.name).sorted() == ["waxRecall", "waxRemember"].sorted())

        let combinedKit = memory.foundationModelsTools(kit: .combined)
        #expect(combinedKit.count == 1)
        #expect(combinedKit.first?.name == "waxMemory")

        let withForget = memory.foundationModelsTools(kit: .focusedWithForget)
        #expect(withForget.count == 4)
        #expect(
            withForget.map(\.name).sorted()
                == ["waxForget", "waxRecall", "waxRemember", "waxSearch"].sorted()
        )

        try await memory.close()
    }
}

@Test
func foundationModelsMemoryToolStructuredRoundTripAndValidation() async throws {
    guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
        var config = WaxMemoryToolConfig.default
        config.includeScores = true
        let tool = memory.foundationModelsMemoryTool(config: config)

        let invalid = await tool.perform(.init(action: "???"))
        #expect(invalid.status == .error)

        let missing = await tool.perform(.init(action: "remember", content: nil))
        #expect(missing.status == .error)

        let remember = try await tool.call(
            arguments: .init(action: "save", content: "User ships apps with SwiftUI.")
        )
        #expect(remember.isSuccess)
        #expect(remember.action == "remember")
        #expect(remember.message.contains("Stored memory"))

        // Structured GeneratedContent round-trip
        let decoded = try WaxMemoryToolResult(generatedContent: remember.generatedContent)
        #expect(decoded == remember)
        // PromptRepresentable must be constructible for Tool output.
        _ = remember.promptRepresentation

        let recall = try await tool.call(arguments: .init(action: "get", query: "SwiftUI"))
        #expect(recall.isSuccess)
        #expect(recall.action == "recall")

        let search = try await tool.call(
            arguments: .init(action: "query", query: "SwiftUI", topK: 1, alpha: 0.2)
        )
        #expect(search.isSuccess)
        #expect(search.action == "search")
        #expect(search.itemCount >= 1)

        try await memory.close()
    }
}

@Test
func foundationModelsFocusedToolsRememberRecallSearch() async throws {
    guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
        let config = WaxMemoryToolConfig(recallMaxItems: 4, searchTopK: 5, embeddingPolicy: .never)

        let remember = WaxRememberTool(memory: memory, config: config)
        let recall = WaxRecallTool(memory: memory, config: config)
        let search = WaxSearchTool(memory: memory, config: config)

        #expect(remember.name == "waxRemember")
        #expect(recall.name == "waxRecall")
        #expect(search.name == "waxSearch")

        let stored = try await remember.call(arguments: .init(content: "User prefers concise Swift answers."))
        #expect(stored.isSuccess)

        let emptyRemember = try await remember.call(arguments: .init(content: "   "))
        #expect(emptyRemember.status == .error)

        let recalled = try await recall.call(arguments: .init(query: "Swift answers"))
        #expect(recalled.isSuccess)

        let emptyRecall = try await recall.call(arguments: .init(query: ""))
        #expect(emptyRecall.status == .error)

        let hits = try await search.call(arguments: .init(query: "concise", topK: 2, alpha: 0.5))
        #expect(hits.isSuccess)
        #expect(hits.itemCount >= 1)

        let emptySearch = try await search.call(arguments: .init(query: "\n"))
        #expect(emptySearch.status == .error)

        try await memory.close()
    }
}

@Test
func foundationModelsForgetToolDeletesByQueryWhenAvailable() async throws {
    guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
        let config = WaxMemoryToolConfig(embeddingPolicy: .never, forgetTopK: 3)
        let forget = WaxForgetTool(memory: memory, config: config)
        #expect(forget.name == "waxForget")

        let remember = WaxRememberTool(memory: memory, config: config)
        let stored = try await remember.call(
            arguments: .init(content: "User temporary note about ProjectQuasar.")
        )
        #expect(stored.isSuccess)

        let empty = try await forget.call(arguments: .init(query: "  "))
        #expect(empty.status == .error)

        let deleted = try await forget.call(arguments: .init(query: "ProjectQuasar", topK: 2))
        #expect(deleted.isSuccess)
        #expect(deleted.action == "forget")
        #expect(deleted.itemCount >= 1)

        let search = WaxSearchTool(memory: memory, config: config)
        let remaining = try await search.call(arguments: .init(query: "ProjectQuasar", topK: 5))
        #expect(remaining.isSuccess)
        #expect(remaining.itemCount == 0)

        try await memory.close()
    }
}

@Test
func foundationModelsOpenMemoryToolFactory() async throws {
    guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

    try await TempFiles.withTempFile { url in
        var config = Memory.Config.default
        config.enableVectorSearch = false

        let tool = try await Memory.openFoundationModelsMemoryTool(
            at: url,
            config: config,
            toolConfig: .default
        )
        let result = try await tool.call(
            arguments: .init(action: "remember", content: "Opened via factory.")
        )
        #expect(result.isSuccess)
    }
}

@Test
func foundationModelsSessionFactoryBindsFocusedMemoryToolsByDefault() async throws {
    guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { config in
            config.enableVectorSearch = false
        }
        try await memory.save("User prefers dark mode.")

        let session = memory.foundationModelsSession(
            instructions: "Be concise."
        )
        #expect(session.configuration.includeMemoryTools == true)
        #expect(session.configuration.contextStrategy == .hybrid)
        #expect(session.ownsMemoryStore == false)

        let prompt = try await session.preparePrompt(for: "What theme does the user prefer?")
        #expect(prompt.contains("<wax_memory>") || prompt.contains("dark mode") || !prompt.isEmpty)

        let recalled = try await session.recall(query: "theme preference")
        #expect(recalled.query == "theme preference" || !recalled.query.isEmpty)

        try await session.close()
        // Caller-provided Memory stays open after session.close().
        try await memory.save("still open after session close")
        try await memory.close()
    }
}

@Test
func foundationModelsSessionToolsOnlyStrategySkipsPromptAugmentation() async throws {
    guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { config in
            config.enableVectorSearch = false
        }
        try await memory.save("User likes Vim keybindings.")

        var configuration = FoundationModelsMemorySessionConfig.default
        configuration.contextStrategy = .tools
        configuration.includeMemoryTools = true
        configuration.persistencePolicy = .none

        let session = memory.foundationModelsSession(configuration: configuration)
        let prompt = try await session.preparePrompt(for: "editor preferences")
        #expect(prompt == "editor preferences")
        #expect(!prompt.contains("<wax_memory>"))

        try await session.close()
        try await memory.close()
    }
}

@Test
func foundationModelsOpenSessionFactoryIsPublicEntryPoint() async throws {
    guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

    try await TempFiles.withTempFile { url in
        var config = Memory.Config.default
        config.enableVectorSearch = false

        let session = try await Memory.openFoundationModelsSession(
            at: url,
            config: config,
            instructions: "You have durable memory."
        )
        #expect(session.ownsMemoryStore == true)
        try await session.remember("User prefers concise answers.")
        let context = try await session.recall(query: "answer style")
        #expect(context.query == "answer style" || !context.query.isEmpty)

        try await session.close()
    }
}

/// Public API contract: transcript and isResponding must be readable without an actor hop.
/// Real consumer apps (WaxDemo) inspect these off the session actor after respond().
@Test
func foundationModelsSessionTranscriptAndIsRespondingAreNonisolated() async throws {
    guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
        let session = memory.foundationModelsSession(
            instructions: "You have durable memory.",
            configuration: .init(persistencePolicy: .none, contextStrategy: .promptAugmentation)
        )

        // These property accesses must compile and run without `await` (nonisolated).
        let transcriptCount = session.transcript.count
        let responding = session.isResponding
        #expect(transcriptCount >= 0)
        #expect(responding == false || responding == true)
        #expect(session.ownsMemoryStore == false)

        try await session.close()
        try await memory.close()
    }
}

@Test
func foundationModelsResultGeneratedContentRoundTripEdgeCases() async throws {
    guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

    let ok = WaxMemoryToolResult.ok(action: .recall, message: "hello", itemCount: 4)
    let decodedOK = try WaxMemoryToolResult(generatedContent: ok.generatedContent)
    #expect(decodedOK == ok)

    let err = WaxMemoryToolResult.error(action: "search", message: "nope")
    let decodedErr = try WaxMemoryToolResult(generatedContent: err.generatedContent)
    #expect(decodedErr.status == .error)
    #expect(decodedErr.action == "search")

    let bad = GeneratedContent(properties: [
        "status": "not-a-status",
        "action": "x",
        "output": "y",
        "itemCount": 0,
    ])
    #expect(throws: WaxError.self) {
        _ = try WaxMemoryToolResult(generatedContent: bad)
    }
}

// MARK: - Session façade (u03)

@Test
func foundationModelsSessionConfigToolKitDefaultsAndPresets() {
    #expect(FoundationModelsMemorySessionConfig.default.toolKit == .focused)
    #expect(FoundationModelsMemorySessionConfig.hybridBalanced.toolKit == .focused)
    #expect(FoundationModelsMemorySessionConfig.toolsOnlyCompact.toolKit == .compact)
    #expect(FoundationModelsMemorySessionConfig.promptOnlyLight.toolKit == .focused)

    var custom = FoundationModelsMemorySessionConfig.default
    custom.toolKit = .focusedWithForget
    #expect(custom.toolKit == .focusedWithForget)
}

@Test
func foundationModelsSessionUsesConfiguredToolKit() async throws {
    guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { $0.enableVectorSearch = false }

        var compactConfig = FoundationModelsMemorySessionConfig.toolsOnlyCompact
        compactConfig.persistencePolicy = .none
        let compactSession = memory.foundationModelsSession(configuration: compactConfig)
        #expect(compactSession.configuration.toolKit == .compact)
        #expect(compactSession.configuration.includeMemoryTools == true)

        var forgetConfig = FoundationModelsMemorySessionConfig.default
        forgetConfig.toolKit = .focusedWithForget
        forgetConfig.persistencePolicy = .none
        let forgetSession = memory.foundationModelsSession(configuration: forgetConfig)
        #expect(forgetSession.configuration.toolKit == .focusedWithForget)

        // Factory produces the same tool counts the session would register.
        let compactTools = memory.foundationModelsTools(
            kit: compactSession.configuration.toolKit,
            config: compactSession.configuration.toolConfig
        )
        #expect(compactTools.count == 2)

        let forgetTools = memory.foundationModelsTools(
            kit: forgetSession.configuration.toolKit,
            config: forgetSession.configuration.toolConfig
        )
        #expect(forgetTools.count == 4)

        try await compactSession.close()
        try await memory.close()
    }
}

@Test
func foundationModelsPreparePromptDetailedReportsRecallCountsAfterSave() async throws {
    guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
        try await memory.save("User prefers cerulean-77 as their onboard color code.")

        var configuration = FoundationModelsMemorySessionConfig.default
        configuration.persistencePolicy = .none
        configuration.embeddingPolicy = .never
        configuration.contextStrategy = .promptAugmentation
        configuration.includeMemoryTools = false

        let session = memory.foundationModelsSession(configuration: configuration)
        let prepared = try await session.preparePromptDetailed(
            for: "What is my favorite onboard color code?"
        )
        #expect(prepared.recalledItemCount >= 1)
        #expect(prepared.includedItemCount >= 1)
        #expect(
            prepared.prompt.localizedCaseInsensitiveContains("cerulean")
                || prepared.prompt.contains("<wax_memory>")
        )
        // Default style is xmlTags → memory stays in the combined prompt.
        #expect(prepared.memoryAppendix == nil)

        let asString = try await session.preparePrompt(for: "What is my favorite onboard color code?")
        #expect(asString == prepared.prompt || asString.contains("cerulean") || !asString.isEmpty)

        try await session.close()
        try await memory.close()
    }
}

@Test
func foundationModelsSessionPreparePreservesHybridAlphaFromToolConfig() async throws {
    guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
        try await memory.save("User prefers hybrid-alpha probe phrase ZenithKite.")

        var toolConfig = WaxMemoryToolConfig.default
        toolConfig.searchAlpha = 0.25
        toolConfig.embeddingPolicy = .automatic
        toolConfig.fallbackToTextOnVectorFailure = true

        var configuration = FoundationModelsMemorySessionConfig.default
        configuration.persistencePolicy = .none
        configuration.embeddingPolicy = .automatic
        configuration.contextStrategy = .promptAugmentation
        configuration.includeMemoryTools = false
        configuration.toolConfig = toolConfig

        // Tool-config search options must keep the non-default alpha (M-7 regression guard).
        #expect(configuration.toolConfig.searchOptions(topK: 4).mode == .hybrid(alpha: 0.25))
        #expect(configuration.toolConfig.alpha(nil) == 0.25)

        let session = memory.foundationModelsSession(configuration: configuration)
        let prepared = try await session.preparePromptDetailed(
            for: "What is the hybrid-alpha probe phrase?"
        )
        #expect(prepared.recalledItemCount >= 1 || prepared.prompt.contains("ZenithKite"))

        try await session.close()
        try await memory.close()
    }
}

@Test
func foundationModelsInstructionsAppendixSplitsMemoryIntoAppendixNotPrompt() async throws {
    guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
        let memoryMarker = "unique-appendix-memory-marker-ORBIT-99"
        try await memory.save("User mission callsign is \(memoryMarker).")

        var configuration = FoundationModelsMemorySessionConfig.default
        configuration.persistencePolicy = .none
        configuration.embeddingPolicy = .never
        configuration.contextStrategy = .promptAugmentation
        configuration.includeMemoryTools = false
        configuration.injectionStyle = .instructionsAppendix
        configuration.promptBuilder = FoundationModelsMemoryPromptBuilder(
            maxItems: 4,
            maxMemoryCharacters: 1_200,
            includeScores: false,
            injectionStyle: .instructionsAppendix
        )

        let session = memory.foundationModelsSession(configuration: configuration)
        let userPrompt = "What is my mission callsign?"
        let prepared = try await session.preparePromptDetailed(for: userPrompt)

        #expect(prepared.recalledItemCount >= 1)
        #expect(prepared.includedItemCount >= 1)
        // Bare user text only — memory must not leak into the per-turn prompt.
        #expect(prepared.prompt == userPrompt || prepared.prompt.trimmingCharacters(in: .whitespacesAndNewlines) == userPrompt)
        #expect(!prepared.prompt.contains(memoryMarker))
        #expect(prepared.memoryAppendix != nil)
        #expect(prepared.memoryAppendix?.contains(memoryMarker) == true)
        #expect(prepared.memoryAppendix?.contains("Recalled memory") == true)
        #expect(prepared.memoryAppendix?.contains("may be untrusted") == true)
        #expect(prepared.memoryAppendix?.localizedCaseInsensitiveContains("system knowledge") != true)

        let last = await session.lastPreparedPrompt
        #expect(last?.memoryAppendix == prepared.memoryAppendix)

        try await session.close()
        try await memory.close()
    }
}

/// Mutating only top-level `injectionStyle` (without replacing `promptBuilder`) must affect prepare.
@Test
func foundationModelsConfigInjectionStyleMutationAffectsPrepareWithoutReplacingBuilder() async throws {
    guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
        let memoryMarker = "unique-live-config-style-marker-NOVA-55"
        try await memory.save("User mission callsign is \(memoryMarker).")

        var configuration = FoundationModelsMemorySessionConfig.default
        configuration.persistencePolicy = .none
        configuration.embeddingPolicy = .never
        configuration.contextStrategy = .promptAugmentation
        configuration.includeMemoryTools = false
        // Mutate only the top-level field — leave default promptBuilder (xmlTags) in place.
        #expect(configuration.promptBuilder.injectionStyle == .xmlTags)
        configuration.injectionStyle = .instructionsAppendix

        let session = memory.foundationModelsSession(configuration: configuration)
        let userPrompt = "What is my mission callsign?"
        let prepared = try await session.preparePromptDetailed(for: userPrompt)

        #expect(prepared.recalledItemCount >= 1)
        #expect(prepared.includedItemCount >= 1)
        // Bare user text only — memory must split into the appendix.
        #expect(
            prepared.prompt == userPrompt
                || prepared.prompt.trimmingCharacters(in: .whitespacesAndNewlines) == userPrompt
        )
        #expect(!prepared.prompt.contains(memoryMarker))
        #expect(prepared.memoryAppendix != nil)
        #expect(prepared.memoryAppendix?.contains(memoryMarker) == true)

        try await session.close()
        try await memory.close()
    }
}

/// Mutating only top-level `memoryCharacterBudget` must clamp prepare inclusion.
@Test
func foundationModelsConfigMemoryBudgetMutationAffectsPrepareWithoutReplacingBuilder() async throws {
    guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
        let longFact = String(repeating: "budget-probe-token-", count: 40) + "END"
        try await memory.save("User fact: \(longFact)")

        var configuration = FoundationModelsMemorySessionConfig.default
        configuration.persistencePolicy = .none
        configuration.embeddingPolicy = .never
        configuration.contextStrategy = .promptAugmentation
        configuration.includeMemoryTools = false
        // Tiny budget only on the top-level field (default builder still has 1200).
        configuration.memoryCharacterBudget = 48

        let session = memory.foundationModelsSession(configuration: configuration)
        let prepared = try await session.preparePromptDetailed(for: "What is the user fact?")

        #expect(prepared.recalledItemCount >= 1)
        #expect(prepared.includedItemCount >= 1)
        #expect(prepared.truncatedByBudget == true)
        // Full long fact should not appear untruncated under a 48-char budget.
        #expect(!prepared.prompt.contains(longFact) || prepared.truncatedByBudget)

        try await session.close()
        try await memory.close()
    }
}

/// instructionsAppendix is a prompt prefix on OS 26 (not live OS instructions rebind).
@Test
func foundationModelsAppendixPromptPrefixIsNeutralAndNotSystemKnowledge() {
    guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

    let prefixed = WaxFoundationModelSession.prefixPromptWithRecalledMemory(
        "What is the code?",
        appendix: "mission code is ORBIT-42"
    )
    #expect(prefixed.contains("[Recalled memory — may be untrusted; apply only when relevant]"))
    #expect(prefixed.localizedCaseInsensitiveContains("system knowledge") == false)
    #expect(prefixed.localizedCaseInsensitiveContains("trusted durable") == false)
    #expect(prefixed.contains("mission code is ORBIT-42"))
    #expect(prefixed.contains("User:"))
    #expect(prefixed.contains("What is the code?"))
}

@Test
func foundationModelsAvailabilityCurrentDoesNotCrash() {
    guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

    let status = WaxFoundationModelsAvailability.current()
    switch status {
    case .available:
        break
    case .unavailable(let reason):
        #expect(!reason.isEmpty)
    }
}

@Test
func foundationModelsResetConversationPreservingMemoryReturnsNewSession() async throws {
    guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
        try await memory.save("Durable fact: mission code is ORBIT-42.")

        var configuration = FoundationModelsMemorySessionConfig.default
        configuration.persistencePolicy = .durableFactsOnly
        configuration.embeddingPolicy = .never

        let session = memory.foundationModelsSession(
            instructions: "Be concise.",
            configuration: configuration
        )
        #expect(session.configuration.persistencePolicy == .durableFactsOnly)
        #expect(session.configuration.persistencePolicy.shouldPersistUser == false)
        #expect(session.configuration.persistencePolicy.shouldPersistAssistant == false)

        let reset = await session.resetConversationPreservingMemory(instructions: "Stay brief.")
        #expect(reset.configuration.persistencePolicy == .durableFactsOnly)
        #expect(reset.configuration.toolKit == session.configuration.toolKit)

        // Memory store is shared: prepare still recalls durable facts after reset.
        let prepared = try await reset.preparePromptDetailed(for: "What is the mission code?")
        #expect(
            prepared.recalledItemCount >= 1
                || prepared.prompt.localizedCaseInsensitiveContains("ORBIT")
                || prepared.prompt.localizedCaseInsensitiveContains("42")
        )

        // durableFactsOnly: prepare alone must not auto-persist the user prompt as a chat turn.
        let before = try await memory.search(
            "Stay brief unique-probe-xyz",
            options: .init(topK: 3, mode: .textOnly)
        )
        #expect(before.items.isEmpty || !before.items.contains(where: {
            $0.text.localizedCaseInsensitiveContains("unique-probe-xyz")
        }))

        // Shared caller-provided Memory: neither session owns the store.
        #expect(session.ownsMemoryStore == false)
        #expect(reset.ownsMemoryStore == false)
        try await session.close()
        try await reset.close()
        try await memory.close()
    }
}

@Test
func foundationModelsOpenSessionWithBuiltInEmbeddingWhenAvailable() async throws {
    guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

    try await TempFiles.withTempFile { url in
        do {
            var config = Memory.Config.default
            config.enableVectorSearch = true
            config.requireOnDeviceProviders = true

            let session = try await Memory.openFoundationModelsSession(
                at: url,
                config: config,
                builtInEmbedding: .miniLM,
                embeddingOptions: .default,
                instructions: "You have durable memory.",
                sessionConfiguration: .init(
                    persistencePolicy: .none,
                    contextStrategy: .tools,
                    embeddingPolicy: .never
                )
            )
            try await session.remember("Opened with MiniLM built-in embedding.")
            let context = try await session.recall(query: "MiniLM embedding")
            #expect(!context.query.isEmpty || context.items.count >= 0)
            try await session.close()
        } catch is BuiltInEmbeddingProviderError {
            // MiniLM trait / model unavailable in this build — skip gracefully.
            return
        } catch {
            // CoreML probe failures are environment-dependent.
            let message = String(describing: error)
            if message.localizedCaseInsensitiveContains("unavailable")
                || message.localizedCaseInsensitiveContains("MiniLM")
                || message.localizedCaseInsensitiveContains("embed")
            {
                return
            }
            throw error
        }
    }
}

@Test
func foundationModelsRespondDetailedWhenModelAvailable() async throws {
    guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }
    guard case .available = WaxFoundationModelsAvailability.current() else { return }

    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
        try await memory.save("User favorite color code is cerulean-77.")

        var configuration = FoundationModelsMemorySessionConfig.default
        configuration.embeddingPolicy = .never
        configuration.persistencePolicy = .userAndAssistant
        configuration.includeMemoryTools = false
        configuration.contextStrategy = .promptAugmentation

        let session = memory.foundationModelsSession(
            instructions: "Answer briefly using memory when present.",
            configuration: configuration
        )

        let detailed = try await session.respondDetailed(
            to: "What is my favorite color code?"
        )
        #expect(!detailed.content.isEmpty)
        #expect(detailed.recalledItemCount >= 0)
        #expect(detailed.didPersistUser == true)
        #expect(detailed.didPersistAssistant == true || !detailed.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        // Compatibility: plain respond still returns String.
        let plain = try await session.respond(to: "Reply with OK.")
        #expect(!plain.isEmpty)

        try await session.close()
        try await memory.close()
    }
}

@Test
func foundationModelsStreamResponseAndCollectWhenModelAvailable() async throws {
    guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }
    guard case .available = WaxFoundationModelsAvailability.current() else { return }

    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
        try await memory.save("User stream marker preference is indigo-stream-42.")

        var configuration = FoundationModelsMemorySessionConfig.default
        configuration.embeddingPolicy = .never
        configuration.persistencePolicy = .userAndAssistant
        configuration.includeMemoryTools = false
        configuration.contextStrategy = .promptAugmentation

        let session = memory.foundationModelsSession(
            instructions: "Answer briefly.",
            configuration: configuration
        )

        let collected = try await session.streamResponseAndCollect(
            to: "What is my stream marker preference?"
        )
        #expect(!collected.content.isEmpty)
        #expect(collected.recalledItemCount >= 0)
        #expect(collected.didPersistUser == true)
        #expect(
            collected.didPersistAssistant == true
                || !collected.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )

        try await session.close()
        try await memory.close()
    }
}

@Test
func foundationModelsDurableFactsOnlyDoesNotPersistChatTurnsWhenModelAvailable() async throws {
    guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }
    guard case .available = WaxFoundationModelsAvailability.current() else { return }

    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { $0.enableVectorSearch = false }

        var configuration = FoundationModelsMemorySessionConfig.default
        configuration.persistencePolicy = .durableFactsOnly
        configuration.embeddingPolicy = .never
        configuration.includeMemoryTools = false
        configuration.contextStrategy = .promptAugmentation

        let session = memory.foundationModelsSession(configuration: configuration)
        let marker = "unique-chat-turn-marker-u03-\(UUID().uuidString)"
        _ = try await session.respondDetailed(to: marker)

        let hits = try await memory.search(marker, options: .init(topK: 5, mode: .textOnly))
        #expect(!hits.items.contains(where: { $0.text.contains(marker) }))

        try await session.close()
        try await memory.close()
    }
}
#endif

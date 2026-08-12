#if canImport(FoundationModels)
import Foundation
import FoundationModels
import WaxCore

/// Detailed result of a Foundation Models generation that also reports memory
/// injection and turn-persistence accounting.
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
public struct WaxFMResponse<Content: Sendable>: Sendable {
    public var content: Content
    public var recalledItemCount: Int
    public var includedItemCount: Int
    public var truncatedByBudget: Bool
    public var didPersistUser: Bool
    public var didPersistAssistant: Bool

    public init(
        content: Content,
        recalledItemCount: Int,
        includedItemCount: Int,
        truncatedByBudget: Bool,
        didPersistUser: Bool,
        didPersistAssistant: Bool
    ) {
        self.content = content
        self.recalledItemCount = recalledItemCount
        self.includedItemCount = includedItemCount
        self.truncatedByBudget = truncatedByBudget
        self.didPersistUser = didPersistUser
        self.didPersistAssistant = didPersistAssistant
    }
}

/// High-level availability of Apple's on-device Foundation Models runtime.
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
public enum WaxFoundationModelsAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)

    /// Maps ``SystemLanguageModel/availability`` into a string-backed summary.
    public static func current(model: SystemLanguageModel = .default) -> Self {
        switch model.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(reason: reasonDescription(reason))
        @unknown default:
            return .unavailable(reason: "unknown")
        }
    }

    private static func reasonDescription(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            return "deviceNotEligible"
        case .appleIntelligenceNotEnabled:
            return "appleIntelligenceNotEnabled"
        case .modelNotReady:
            return "modelNotReady"
        @unknown default:
            return String(describing: reason)
        }
    }
}

/// A memory-backed Foundation Models chat session.
///
/// This is the recommended way to use Wax as long-term memory for Apple's on-device
/// Foundation Models framework. By default it:
/// 1. Recalls relevant context and injects it into the prompt
/// 2. Registers a ``WaxMemoryTool`` so the model can actively remember/recall
/// 3. Optionally persists each turn back into the Wax store
///
/// ## Memory ownership
///
/// - Sessions created from an existing ``Memory`` (``Memory/foundationModelsSession``)
///   do **not** own the store: ``close()`` leaves ``Memory`` open for siblings/tools.
/// - Sessions created via ``Memory/openFoundationModelsSession`` open the store and
///   own it: ``close()`` closes the underlying ``Memory``.
///
/// ```swift
/// let memory = try await Memory(at: storeURL)
/// let session = memory.foundationModelsSession(
///     instructions: "You are a helpful assistant with durable memory."
/// )
/// let answer = try await session.respond(to: "What editor do I prefer?")
/// try await session.close() // does not close `memory`
/// try await memory.close()
/// ```
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
public actor WaxFoundationModelSession {
    private let memory: Memory
    private let model: SystemLanguageModel
    private let userInstructions: String?
    private let additionalTools: [any Tool]
    /// When `true`, ``close()`` closes the underlying ``Memory`` (session opened the store).
    private let ownsMemory: Bool
    private let generator: any WaxFoundationModelGenerating
    private let generationGate = AsyncMutex()

    /// Underlying Foundation Models session. Use for advanced multi-turn control.
    public nonisolated let languageModelSession: LanguageModelSession
    /// Immutable session configuration (safe to read off the actor).
    public nonisolated let configuration: FoundationModelsMemorySessionConfig

    /// Whether ``close()`` will close the underlying ``Memory`` store.
    ///
    /// `true` only for sessions that opened the store (e.g. ``Memory/openFoundationModelsSession``).
    public nonisolated var ownsMemoryStore: Bool { ownsMemory }

    /// Last prompt-prep accounting (updated by ``preparePromptDetailed(for:)``).
    public private(set) var lastPreparedPrompt: PreparedMemoryPrompt?

    public init(
        memory: Memory,
        model: SystemLanguageModel = .default,
        instructions: String? = nil,
        additionalTools: [any Tool] = [],
        configuration: FoundationModelsMemorySessionConfig = .default,
        ownsMemory: Bool = false
    ) {
        self.memory = memory
        self.model = model
        self.userInstructions = instructions
        self.additionalTools = additionalTools
        self.configuration = configuration
        self.ownsMemory = ownsMemory

        let tools = Self.assembleTools(
            memory: memory,
            additionalTools: additionalTools,
            configuration: configuration
        )
        let resolvedInstructions = Self.defaultInstructions(
            userInstructions: instructions,
            includesMemoryTools: configuration.includeMemoryTools,
            toolKit: configuration.toolKit
        )
        self.languageModelSession = LanguageModelSession(
            model: model,
            tools: tools,
            instructions: resolvedInstructions
        )
        self.generator = LiveLanguageModelGenerator(session: languageModelSession)
        self.languageModelSession.prewarm()
    }

    /// Test-only session that drives generation through `generator` instead of the live model.
    /// Still constructs a ``LanguageModelSession`` for the public handle; it is not prewarmed.
    package init(
        memory: Memory,
        instructions: String? = nil,
        additionalTools: [any Tool] = [],
        configuration: FoundationModelsMemorySessionConfig = .default,
        ownsMemory: Bool = false,
        generator: any WaxFoundationModelGenerating
    ) {
        self.memory = memory
        self.model = .default
        self.userInstructions = instructions
        self.additionalTools = additionalTools
        self.configuration = configuration
        self.ownsMemory = ownsMemory
        self.generator = generator

        let tools = Self.assembleTools(
            memory: memory,
            additionalTools: additionalTools,
            configuration: configuration
        )
        let resolvedInstructions = Self.defaultInstructions(
            userInstructions: instructions,
            includesMemoryTools: configuration.includeMemoryTools,
            toolKit: configuration.toolKit
        )
        self.languageModelSession = LanguageModelSession(
            model: .default,
            tools: tools,
            instructions: resolvedInstructions
        )
    }

    public init(
        memory: Memory,
        model: SystemLanguageModel = .default,
        additionalTools: [any Tool] = [],
        configuration: FoundationModelsMemorySessionConfig = .default,
        ownsMemory: Bool = false,
        @InstructionsBuilder instructions: () throws -> Instructions
    ) rethrows {
        self.memory = memory
        self.model = model
        // InstructionsBuilder content is not a String; reset falls back to configuration-only.
        self.userInstructions = nil
        self.additionalTools = additionalTools
        self.configuration = configuration
        self.ownsMemory = ownsMemory

        let tools = Self.assembleTools(
            memory: memory,
            additionalTools: additionalTools,
            configuration: configuration
        )
        let built = try instructions()
        self.languageModelSession = LanguageModelSession(
            model: model,
            tools: tools,
            instructions: built
        )
        self.generator = LiveLanguageModelGenerator(session: languageModelSession)
        self.languageModelSession.prewarm()
    }

    /// Builds the memory-augmented prompt sent to Foundation Models (when prompt augmentation is enabled).
    public func preparePrompt(for userPrompt: String) async throws -> String {
        try await preparePromptDetailed(for: userPrompt).prompt
    }

    /// Builds a memory-augmented prompt and returns budget / recall accounting.
    public func preparePromptDetailed(for userPrompt: String) async throws -> PreparedMemoryPrompt {
        guard configuration.shouldAugmentPrompt else {
            let prepared = PreparedMemoryPrompt(
                prompt: userPrompt,
                includedItemCount: 0,
                recalledItemCount: 0,
                truncatedByBudget: false,
                memoryAppendix: nil
            )
            lastPreparedPrompt = prepared
            return prepared
        }

        // Top-level config fields are authoritative after mutation; keep promptBuilder's
        // maxItems/includeScores but always apply injectionStyle + memoryCharacterBudget.
        var builder = configuration.promptBuilder
        builder.injectionStyle = configuration.injectionStyle
        builder.maxMemoryCharacters = configuration.memoryCharacterBudget

        // Same search + vector→text fallback path as memory tools (M-8).
        // Session embeddingPolicy overrides toolConfig; hybrid alpha comes from toolConfig (M-7).
        let context = try await WaxMemoryToolExecutor.searchWithFallback(
            memory: memory,
            config: configuration.toolConfig,
            query: userPrompt,
            topK: max(1, builder.maxItems),
            alpha: nil,
            embeddingPolicy: configuration.embeddingPolicy
        )
        let prepared = builder.prepare(userPrompt: userPrompt, context: context)
        lastPreparedPrompt = prepared
        return prepared
    }

    /// Generates a text response and optionally persists both sides of the turn.
    @discardableResult
    public func respond(
        to userPrompt: String,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> String {
        try await respondDetailed(to: userPrompt, options: options).content
    }

    /// Generates a text response and returns memory / persistence accounting.
    @discardableResult
    public func respondDetailed(
        to userPrompt: String,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> WaxFMResponse<String> {
        try await withGenerationLease {
            let prepared = try await self.preparePromptDetailed(for: userPrompt)
            let turn = self.invocationForTurn(prepared: prepared)
            let response = try await self.generator.generateText(
                prompt: turn.prompt,
                options: options
            )
            let persistence = try await self.persistTurnTracked(
                userPrompt: userPrompt,
                assistantResponse: response
            )
            return WaxFMResponse(
                content: response,
                recalledItemCount: prepared.recalledItemCount,
                includedItemCount: prepared.includedItemCount,
                truncatedByBudget: prepared.truncatedByBudget,
                didPersistUser: persistence.didPersistUser,
                didPersistAssistant: persistence.didPersistAssistant
            )
        }
    }

    /// Generates a structured response and optionally persists the turn.
    ///
    /// When assistant persistence is enabled, structured values are serialized according
    /// to ``FoundationModelsMemorySessionConfig/structuredPersistence``.
    @discardableResult
    public func respond<T: Generable>(
        to userPrompt: String,
        generating type: T.Type,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> T {
        try await withGenerationLease {
            let prepared = try await self.preparePromptDetailed(for: userPrompt)
            let turn = self.invocationForTurn(prepared: prepared)
            let response = try await self.generator.generateStructured(
                prompt: turn.prompt,
                type: type,
                options: options
            )
            if let serialized = self.serializeStructured(response) {
                try await self.persistTurn(userPrompt: userPrompt, assistantResponse: serialized)
            } else if self.configuration.persistencePolicy.shouldPersistUser {
                try await self.persistUser(userPrompt)
            }
            return response
        }
    }

    /// Generates a structured response and returns memory / persistence accounting.
    ///
    /// Requires `T: Sendable` so the detailed response can cross concurrency boundaries.
    @discardableResult
    public func respondDetailed<T: Generable & Sendable>(
        to userPrompt: String,
        generating type: T.Type,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> WaxFMResponse<T> {
        try await withGenerationLease {
            let prepared = try await self.preparePromptDetailed(for: userPrompt)
            let turn = self.invocationForTurn(prepared: prepared)
            let response = try await self.generator.generateStructured(
                prompt: turn.prompt,
                type: type,
                options: options
            )
            let serialized = self.serializeStructured(response)
            let persistence: (didPersistUser: Bool, didPersistAssistant: Bool)
            if let serialized {
                persistence = try await self.persistTurnTracked(
                    userPrompt: userPrompt,
                    assistantResponse: serialized
                )
            } else {
                var didPersistUser = false
                if self.configuration.persistencePolicy.shouldPersistUser {
                    didPersistUser = try await self.persistUserTracked(userPrompt)
                }
                persistence = (didPersistUser, false)
            }
            return WaxFMResponse(
                content: response,
                recalledItemCount: prepared.recalledItemCount,
                includedItemCount: prepared.includedItemCount,
                truncatedByBudget: prepared.truncatedByBudget,
                didPersistUser: persistence.didPersistUser,
                didPersistAssistant: persistence.didPersistAssistant
            )
        }
    }

    /// Streams a text response. User turns are persisted when configured; assistant
    /// persistence is skipped because the full response is not available until collection.
    public func streamResponse(
        to userPrompt: String,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> WaxGenerationLeaseStream {
        await generationGate.lock()
        let lease = GenerationLease(gate: generationGate)
        do {
            try Task.checkCancellation()
            let prepared = try await preparePromptDetailed(for: userPrompt)
            if configuration.persistencePolicy.shouldPersistUser {
                _ = try await persistUserTracked(userPrompt)
            }
            let turn = invocationForTurn(prepared: prepared)
            let inner = generator.streamText(prompt: turn.prompt, options: options)
            return WaxGenerationLeaseStream(
                stream: AsyncThrowingStream { continuation in
                    let task = Task {
                        defer { lease.release() }
                        do {
                            for try await element in inner {
                                try Task.checkCancellation()
                                continuation.yield(element)
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { _ in
                        task.cancel()
                    }
                }
            )
        } catch {
            lease.release()
            throw error
        }
    }

    /// Streams a text response, collects the full assistant text, and persists both sides
    /// of the turn when the session persistence policy allows.
    @discardableResult
    public func streamResponseAndCollect(
        to userPrompt: String,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> WaxFMResponse<String> {
        try await withGenerationLease {
            let prepared = try await self.preparePromptDetailed(for: userPrompt)
            let turn = self.invocationForTurn(prepared: prepared)
            let content = try await WaxGenerationLeaseStream(
                stream: self.generator.streamText(prompt: turn.prompt, options: options)
            ).collect()
            let persistence = try await self.persistTurnTracked(
                userPrompt: userPrompt,
                assistantResponse: content
            )
            return WaxFMResponse(
                content: content,
                recalledItemCount: prepared.recalledItemCount,
                includedItemCount: prepared.includedItemCount,
                truncatedByBudget: prepared.truncatedByBudget,
                didPersistUser: persistence.didPersistUser,
                didPersistAssistant: persistence.didPersistAssistant
            )
        }
    }

    /// Returns a **new** session wrapping the same ``Memory`` and configuration, with a
    /// fresh ``LanguageModelSession`` transcript.
    ///
    /// Callers should replace their handle with the returned value. The previous session
    /// remains usable until closed; both share the underlying store. Ownership of the store
    /// is **not** transferred — the returned session never owns ``Memory`` (`ownsMemoryStore`
    /// is `false`); close the original owner or the ``Memory`` handle explicitly.
    public func resetConversationPreservingMemory(
        instructions: String? = nil
    ) -> WaxFoundationModelSession {
        WaxFoundationModelSession(
            memory: memory,
            model: model,
            instructions: instructions ?? userInstructions,
            additionalTools: additionalTools,
            configuration: configuration,
            ownsMemory: false
        )
    }

    /// Persists content directly into the underlying Wax store.
    public func remember(_ content: String, metadata: [String: String] = [:]) async throws {
        try await memory.save(content, metadata: metadata)
    }

    /// Recalls memory context directly from the underlying Wax store.
    ///
    /// Uses the same vector→text fallback path as tools when
    /// ``WaxMemoryToolConfig/fallbackToTextOnVectorFailure`` is true.
    public func recall(query: String) async throws -> RAGContext {
        try await WaxMemoryToolExecutor.searchWithFallback(
            memory: memory,
            config: configuration.toolConfig,
            query: query,
            topK: max(1, configuration.promptBuilder.maxItems),
            alpha: nil,
            embeddingPolicy: configuration.embeddingPolicy
        )
    }

    /// The live multi-turn transcript managed by Foundation Models.
    ///
    /// Nonisolated: forwards to the nonisolated ``languageModelSession`` handle so callers
    /// can inspect transcript state without hopping onto the session actor.
    public nonisolated var transcript: Transcript {
        languageModelSession.transcript
    }

    /// Whether the underlying model is currently generating.
    ///
    /// Nonisolated: forwards to the nonisolated ``languageModelSession`` handle.
    public nonisolated var isResponding: Bool {
        languageModelSession.isResponding
    }

    /// Flushes pending memory writes without closing the store.
    public func flush() async throws {
        try await memory.flush()
    }

    /// Releases session-owned resources.
    ///
    /// When ``ownsMemoryStore`` is `true` (session opened the store), closes the underlying
    /// ``Memory``. When the caller supplied ``Memory``, this is a no-op on the store so
    /// sibling sessions and tools can keep using it — call ``Memory/close()`` separately.
    public func close() async throws {
        if ownsMemory {
            try await memory.close()
        }
    }

    // MARK: - Persistence helpers

    /// FIFO generation lease. Actor isolation is reentrant, so overlapping
    /// `respond`/`streamResponse` calls must not rely on it to keep Apple's
    /// ``LanguageModelSession`` single-flight.
    private func withGenerationLease<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        await generationGate.lock()
        do {
            try Task.checkCancellation()
            let value = try await operation()
            await generationGate.unlock()
            return value
        } catch {
            await generationGate.unlock()
            throw error
        }
    }

    private func persistTurn(userPrompt: String, assistantResponse: String) async throws {
        _ = try await persistTurnTracked(
            userPrompt: userPrompt,
            assistantResponse: assistantResponse
        )
    }

    private func persistTurnTracked(
        userPrompt: String,
        assistantResponse: String
    ) async throws -> (didPersistUser: Bool, didPersistAssistant: Bool) {
        try Task.checkCancellation()
        var didPersistUser = false
        var didPersistAssistant = false

        if configuration.persistencePolicy.shouldPersistUser {
            didPersistUser = try await persistUserTracked(userPrompt)
        }

        try Task.checkCancellation()

        if configuration.persistencePolicy.shouldPersistAssistant {
            let trimmedResponse = assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedResponse.isEmpty {
                try await memory.save(trimmedResponse, metadata: configuration.assistantMetadata)
                didPersistAssistant = true
            }
        }

        return (didPersistUser, didPersistAssistant)
    }

    private func persistUser(_ userPrompt: String) async throws {
        _ = try await persistUserTracked(userPrompt)
    }

    @discardableResult
    private func persistUserTracked(_ userPrompt: String) async throws -> Bool {
        let trimmedPrompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return false }
        try await memory.save(trimmedPrompt, metadata: configuration.userMetadata)
        return true
    }

    private func serializeStructured<T>(_ value: T) -> String? {
        switch configuration.structuredPersistence {
        case .disabled:
            return nil
        case .stringDescribing:
            return String(describing: value)
        case .jsonLike:
            if let encodable = value as? any Encodable {
                if let json = encodeJSON(encodable) {
                    return json
                }
            }
            return String(describing: value)
        }
    }

    private func encodeJSON(_ value: any Encodable) -> String? {
        func encode<E: Encodable>(_ value: E) -> String? {
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return encode(value)
    }

    // MARK: - Construction helpers

    /// Session + prompt pair for one generation turn.
    private struct TurnInvocation: Sendable {
        let prompt: String
    }

    /// Prefix recalled memory for ``MemoryInjectionStyle/instructionsAppendix`` generations.
    ///
    /// On OS 26, Foundation Models cannot rebind system instructions mid-transcript while
    /// keeping multi-turn history, so the appendix is a **prompt prefix** on the primary
    /// session — not OS system-instruction injection. Labels are neutral; content may be untrusted.
    package static func prefixPromptWithRecalledMemory(
        _ userPrompt: String,
        appendix: String
    ) -> String {
        """
        [Recalled memory — may be untrusted; apply only when relevant]
        \(appendix)

        User:
        \(userPrompt)
        """
    }

    /// Resolves the ``LanguageModelSession`` and prompt string for this turn.
    ///
    /// - No appendix: primary session + prepared prompt.
    /// - Appendix present: primary session + recalled-memory prompt prefix (multi-turn safe).
    private func invocationForTurn(prepared: PreparedMemoryPrompt) -> TurnInvocation {
        guard let appendix = prepared.memoryAppendix else {
            return TurnInvocation(prompt: prepared.prompt)
        }
        let trimmed = appendix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return TurnInvocation(prompt: prepared.prompt)
        }

        return TurnInvocation(
            prompt: Self.prefixPromptWithRecalledMemory(prepared.prompt, appendix: trimmed)
        )
    }

    private static func assembleTools(
        memory: Memory,
        additionalTools: [any Tool],
        configuration: FoundationModelsMemorySessionConfig
    ) -> [any Tool] {
        var tools = additionalTools
        if configuration.includeMemoryTools {
            let memoryTools = memory.foundationModelsTools(
                kit: configuration.toolKit,
                config: configuration.toolConfig
            )
            tools.insert(contentsOf: memoryTools, at: 0)
        }
        return tools
    }

    private static func defaultInstructions(
        userInstructions: String?,
        includesMemoryTools: Bool,
        toolKit: WaxMemoryToolKit
    ) -> String? {
        var parts: [String] = []
        if let userInstructions {
            let trimmed = userInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                parts.append(trimmed)
            }
        }
        if includesMemoryTools {
            parts.append(memoryToolsInstructions(for: toolKit))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }

    private static func memoryToolsInstructions(for toolKit: WaxMemoryToolKit) -> String {
        switch toolKit {
        case .focused:
            return """
            You have durable on-device memory via three tools:
            - waxRemember: store durable facts, preferences, and decisions.
            - waxRecall: retrieve the best context for a natural-language query.
            - waxSearch: ranked memory hits when you need broader retrieval (optional topK).
            Only store durable information; do not store secrets or one-off ephemeral chatter.
            """
        case .compact:
            return """
            You have durable on-device memory via two tools:
            - waxRemember: store durable facts, preferences, and decisions.
            - waxRecall: retrieve the best context for a natural-language query.
            Only store durable information; do not store secrets or one-off ephemeral chatter.
            """
        case .combined:
            return """
            You have durable on-device memory via the waxMemory tool (remember / recall / search / forget actions).
            Only store durable information; do not store secrets or one-off ephemeral chatter.
            """
        case .focusedWithForget:
            return """
            You have durable on-device memory via four tools:
            - waxRemember: store durable facts, preferences, and decisions.
            - waxRecall: retrieve the best context for a natural-language query.
            - waxSearch: ranked memory hits when you need broader retrieval (optional topK).
            - waxForget: delete memories that match a query when the user asks to forget something.
            Only store durable information; do not store secrets or one-off ephemeral chatter.
            """
        }
    }
}

@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
public extension Memory {
    /// Creates a memory-backed Foundation Models session from this store.
    ///
    /// Nonisolated: only captures the `Memory` handle; no actor state is read.
    nonisolated func foundationModelsSession(
        model: SystemLanguageModel = .default,
        instructions: String? = nil,
        additionalTools: [any Tool] = [],
        configuration: FoundationModelsMemorySessionConfig = .default
    ) -> WaxFoundationModelSession {
        WaxFoundationModelSession(
            memory: self,
            model: model,
            instructions: instructions,
            additionalTools: additionalTools,
            configuration: configuration
        )
    }

    /// Opens a store and returns a memory-backed Foundation Models session that **owns**
    /// the store (``WaxFoundationModelSession/close()`` closes ``Memory``).
    static func openFoundationModelsSession(
        at url: URL,
        config: Config = .default,
        embedding: (any EmbeddingProvider)? = nil,
        model: SystemLanguageModel = .default,
        instructions: String? = nil,
        additionalTools: [any Tool] = [],
        sessionConfiguration: FoundationModelsMemorySessionConfig = .default
    ) async throws -> WaxFoundationModelSession {
        var config = config
        if let embedding {
            config.embedding = .custom(embedding)
        }
        let memory = try await Memory(at: url, config: config)
        return WaxFoundationModelSession(
            memory: memory,
            model: model,
            instructions: instructions,
            additionalTools: additionalTools,
            configuration: sessionConfiguration,
            ownsMemory: true
        )
    }

    /// Opens a store with a built-in embedding provider and returns a memory-backed
    /// Foundation Models session that **owns** the store.
    static func openFoundationModelsSession(
        at url: URL,
        config: Config = .default,
        builtInEmbedding: BuiltInEmbeddingProvider,
        embeddingOptions: BuiltInEmbeddingProviderOptions = .default,
        model: SystemLanguageModel = .default,
        instructions: String? = nil,
        additionalTools: [any Tool] = [],
        sessionConfiguration: FoundationModelsMemorySessionConfig = .default
    ) async throws -> WaxFoundationModelSession {
        var config = config
        config.embedding = .builtIn(builtInEmbedding, embeddingOptions)
        let memory = try await Memory(at: url, config: config)
        return WaxFoundationModelSession(
            memory: memory,
            model: model,
            instructions: instructions,
            additionalTools: additionalTools,
            configuration: sessionConfiguration,
            ownsMemory: true
        )
    }
}

// Package-compatible bridge for existing in-module callers that still use MemoryOrchestrator.
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
package extension MemoryOrchestrator {
    /// Creates a memory-backed Foundation Models session from an existing orchestrator.
    func foundationModelsSession(
        model: SystemLanguageModel = .default,
        instructions: String? = nil,
        additionalTools: [any Tool] = [],
        configuration: FoundationModelsMemorySessionConfig = .default
    ) -> WaxFoundationModelSession {
        let memory = Memory(orchestrator: self)
        return WaxFoundationModelSession(
            memory: memory,
            model: model,
            instructions: instructions,
            additionalTools: additionalTools,
            configuration: configuration
        )
    }

    /// Opens a store and returns a memory-backed Foundation Models session that **owns**
    /// the store.
    static func openFoundationModelsSession(
        at url: URL,
        config: OrchestratorConfig = .default,
        embedder: (any EmbeddingProvider)? = nil,
        model: SystemLanguageModel = .default,
        instructions: String? = nil,
        additionalTools: [any Tool] = [],
        sessionConfiguration: FoundationModelsMemorySessionConfig = .default
    ) async throws -> WaxFoundationModelSession {
        let orchestrator = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: embedder
        )
        let memory = Memory(orchestrator: orchestrator)
        return WaxFoundationModelSession(
            memory: memory,
            model: model,
            instructions: instructions,
            additionalTools: additionalTools,
            configuration: sessionConfiguration,
            ownsMemory: true
        )
    }
}
#endif

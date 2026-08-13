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
    public var retrievalDiagnostics: RAGContext.Diagnostics?
    public var estimatedPreparedCharacters: Int
    public var resetTranscriptForContext: Bool
    public var preparedPromptTokenCount: Int
    public var contextWindowTokens: Int?
    public var estimatedContextTokens: Int
    public var remainingContextTokens: Int?
    public var truncationStrategy: String

    public init(
        content: Content,
        recalledItemCount: Int,
        includedItemCount: Int,
        truncatedByBudget: Bool,
        didPersistUser: Bool,
        didPersistAssistant: Bool,
        retrievalDiagnostics: RAGContext.Diagnostics? = nil,
        estimatedPreparedCharacters: Int = 0,
        resetTranscriptForContext: Bool = false,
        preparedPromptTokenCount: Int = 0,
        contextWindowTokens: Int? = nil,
        estimatedContextTokens: Int = 0,
        remainingContextTokens: Int? = nil,
        truncationStrategy: String = "none"
    ) {
        self.content = content
        self.recalledItemCount = recalledItemCount
        self.includedItemCount = includedItemCount
        self.truncatedByBudget = truncatedByBudget
        self.didPersistUser = didPersistUser
        self.didPersistAssistant = didPersistAssistant
        self.retrievalDiagnostics = retrievalDiagnostics
        self.estimatedPreparedCharacters = estimatedPreparedCharacters
        self.resetTranscriptForContext = resetTranscriptForContext
        self.preparedPromptTokenCount = preparedPromptTokenCount
        self.contextWindowTokens = contextWindowTokens
        self.estimatedContextTokens = estimatedContextTokens
        self.remainingContextTokens = remainingContextTokens
        self.truncationStrategy = truncationStrategy
    }
}

@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
extension WaxFMResponse: Equatable where Content: Equatable {}

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
    private var generator: any WaxFoundationModelGenerating
    private let generationGate = AsyncMutex()
    /// Incremented immediately before each mutex unlock so inherited TaskLocal
    /// snapshots from escaped unstructured children cannot bypass a later holder.
    private var generationLeaseEpoch: UInt64 = 0
    /// True while an owning ``WaxGenerationStream`` holds the generation lease.
    /// Concurrent ``streamResponse`` callers fail with
    /// ``WaxFoundationModelsError/generationInProgress`` instead of queueing;
    /// non-streaming ``respond`` calls still FIFO-wait.
    private var isStreaming = false
    private var completedTurns = 0
    private var resetTranscriptForContext = false
    private let sessionBox: LanguageModelSessionBox

    /// Package-only Apple session handle (prewarm, overflow reset, tests).
    ///
    /// Decision (C-P2-3): this is **not** public. A public accessor would bypass
    /// ``generationGate`` and let callers overlap Apple requests. Use ``respond`` /
    /// ``streamResponse``; inspect ``transcript`` / ``isResponding`` for status.
    package nonisolated var languageModelSession: LanguageModelSession {
        sessionBox.session
    }
    /// Immutable session configuration (safe to read off the actor).
    public nonisolated let configuration: FoundationModelsMemorySessionConfig

    /// Whether ``close()`` will close the underlying ``Memory`` store.
    ///
    /// `true` only for sessions that opened the store (e.g. ``Memory/openFoundationModelsSession``).
    public nonisolated var ownsMemoryStore: Bool { ownsMemory }

    /// Last prompt-prep accounting (updated by ``preparePromptDetailed(for:)``).
    public private(set) var lastPreparedPrompt: PreparedMemoryPrompt?

    /// Creates a session that does **not** own `memory`. ``close()`` leaves the store open.
    ///
    /// Store-owning sessions come from ``Memory/openFoundationModelsSession``. Public
    /// callers cannot pass `ownsMemory:` — that would let `close()` shut a store the
    /// caller still holds.
    public init(
        memory: Memory,
        model: SystemLanguageModel = .default,
        instructions: String? = nil,
        additionalTools: [any Tool] = [],
        configuration: FoundationModelsMemorySessionConfig = .default
    ) {
        self.init(
            memory: memory,
            model: model,
            instructions: instructions,
            additionalTools: additionalTools,
            configuration: configuration,
            ownsMemory: false
        )
    }

    /// Designated session initializer. `ownsMemory: true` is reserved for
    /// ``Memory/openFoundationModelsSession`` (and in-package owning factories).
    package init(
        memory: Memory,
        model: SystemLanguageModel = .default,
        instructions: String? = nil,
        additionalTools: [any Tool] = [],
        configuration: FoundationModelsMemorySessionConfig = .default,
        ownsMemory: Bool
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
        let appleSession = LanguageModelSession(
            model: model,
            tools: tools,
            instructions: resolvedInstructions
        )
        self.sessionBox = LanguageModelSessionBox(appleSession)
        self.generator = LiveLanguageModelGenerator(session: appleSession)
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
        let appleSession = LanguageModelSession(
            model: .default,
            tools: tools,
            instructions: resolvedInstructions
        )
        self.sessionBox = LanguageModelSessionBox(appleSession)
    }

    public init(
        memory: Memory,
        model: SystemLanguageModel = .default,
        additionalTools: [any Tool] = [],
        configuration: FoundationModelsMemorySessionConfig = .default,
        @InstructionsBuilder instructions: () throws -> Instructions
    ) rethrows {
        self.memory = memory
        self.model = model
        // InstructionsBuilder content is not a String; reset falls back to configuration-only.
        self.userInstructions = nil
        self.additionalTools = additionalTools
        self.configuration = configuration
        self.ownsMemory = false

        let tools = Self.assembleTools(
            memory: memory,
            additionalTools: additionalTools,
            configuration: configuration
        )
        let built = try instructions()
        let appleSession = LanguageModelSession(
            model: model,
            tools: tools,
            instructions: built
        )
        self.sessionBox = LanguageModelSessionBox(appleSession)
        self.generator = LiveLanguageModelGenerator(session: appleSession)
    }

    /// Builds the memory-augmented prompt sent to Foundation Models (when prompt augmentation is enabled).
    public func preparePrompt(for userPrompt: String) async throws -> String {
        try await preparePromptDetailed(for: userPrompt).prompt
    }

    /// Builds a memory-augmented prompt and returns budget / recall accounting.
    ///
    /// Serialized with the generation lease so a concurrent prepare cannot
    /// overwrite ``lastPreparedPrompt`` used by an in-flight persist (C-P2-4).
    ///
    /// The lease is re-entrant for the task that already holds the *current*
    /// generation epoch: a custom Foundation Models tool invoked during
    /// ``respond`` / ``streamResponse`` may call this method without deadlocking.
    /// Independent tasks, and unstructured `Task {}` children that outlive the
    /// owning operation, wait until the in-flight generation (or prepare)
    /// releases the lease.
    public func preparePromptDetailed(for userPrompt: String) async throws -> PreparedMemoryPrompt {
        try await withGenerationLease {
            try await self.preparePromptDetailedUngated(for: userPrompt)
        }
    }

    private func preparePromptDetailedUngated(for userPrompt: String) async throws -> PreparedMemoryPrompt {
        guard configuration.shouldAugmentPrompt else {
            var prepared = PreparedMemoryPrompt(
                prompt: userPrompt,
                includedItemCount: 0,
                recalledItemCount: 0,
                truncatedByBudget: false,
                memoryAppendix: nil,
                estimatedPreparedCharacters: userPrompt.count
            )
            prepared = try await Self.annotatePreparedPrompt(
                prepared,
                context: nil,
                finalPrompt: userPrompt
            )
            try throwIfPreparedPromptOverflows(prepared)
            lastPreparedPrompt = prepared
            return prepared
        }

        let builder = configuration.promptBuilder
        let context = try await WaxMemoryToolExecutor.searchWithFallback(
            memory: memory,
            config: configuration.toolConfig,
            query: userPrompt,
            topK: max(1, builder.maxItems),
            alpha: nil,
            embeddingPolicy: configuration.embeddingPolicy
        )
        var prepared = builder.prepare(userPrompt: userPrompt, context: context)
        let turn = invocationForTurn(prepared: prepared)
        prepared = try await Self.annotatePreparedPrompt(
            prepared,
            context: context,
            finalPrompt: turn.prompt
        )
        try throwIfPreparedPromptOverflows(prepared)
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
            let prepared = try await self.preparePromptDetailedUngated(for: userPrompt)
            let turn = self.invocationForTurn(prepared: prepared)
            try self.checkConversationTurnLimit()
            let response: String
            do {
                response = try await self.generateTextHonoringOverflowPolicy(
                    prompt: turn.prompt,
                    options: options
                )
            } catch {
                throw self.mapTerminalError(error, prepared: prepared, didPersistUser: false)
            }
            let persistence: (didPersistUser: Bool, didPersistAssistant: Bool)
            do {
                persistence = try await self.persistTurnTracked(
                    userPrompt: userPrompt,
                    assistantResponse: response,
                    prepared: prepared
                )
            } catch {
                throw self.mapTerminalError(error, prepared: prepared, didPersistUser: false)
            }
            self.completedTurns += 1
            return self.makeResponse(
                content: response,
                prepared: prepared,
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
            let prepared = try await self.preparePromptDetailedUngated(for: userPrompt)
            let turn = self.invocationForTurn(prepared: prepared)
            try self.checkConversationTurnLimit()
            let response: T
            do {
                response = try await self.generateStructuredHonoringOverflowPolicy(
                    prompt: turn.prompt,
                    type: type,
                    options: options
                )
            } catch {
                throw self.mapTerminalError(error, prepared: prepared, didPersistUser: false)
            }
            if let serialized = self.serializeStructured(response) {
                try await self.persistTurn(
                    userPrompt: userPrompt,
                    assistantResponse: serialized,
                    prepared: prepared
                )
            } else if self.configuration.persistencePolicy.shouldPersistUser {
                try await self.persistUser(userPrompt)
            }
            self.completedTurns += 1
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
            let prepared = try await self.preparePromptDetailedUngated(for: userPrompt)
            let turn = self.invocationForTurn(prepared: prepared)
            try self.checkConversationTurnLimit()
            let response: T
            do {
                response = try await self.generateStructuredHonoringOverflowPolicy(
                    prompt: turn.prompt,
                    type: type,
                    options: options
                )
            } catch {
                throw self.mapTerminalError(error, prepared: prepared, didPersistUser: false)
            }
            let serialized = self.serializeStructured(response)
            let persistence: (didPersistUser: Bool, didPersistAssistant: Bool)
            if let serialized {
                persistence = try await self.persistTurnTracked(
                    userPrompt: userPrompt,
                    assistantResponse: serialized,
                    prepared: prepared
                )
            } else {
                var didPersistUser = false
                if self.configuration.persistencePolicy.shouldPersistUser {
                    didPersistUser = try await self.persistUserTracked(userPrompt)
                }
                persistence = (didPersistUser, false)
            }
            self.completedTurns += 1
            return self.makeResponse(
                content: response,
                prepared: prepared,
                didPersistUser: persistence.didPersistUser,
                didPersistAssistant: persistence.didPersistAssistant
            )
        }
    }

    /// Streams a text response as an owning ``WaxGenerationStream``.
    ///
    /// The generation lease is held until the stream completes, fails, is cancelled,
    /// or is dropped. Persistence: nothing before the first ``WaxGenerationStream/Event/content``;
    /// user on first content (if policy requires it); assistant only on normal completion.
    /// A second concurrent ``streamResponse`` fails with
    /// ``WaxFoundationModelsError/generationInProgress``.
    public func streamResponse(
        to userPrompt: String,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> WaxGenerationStream {
        if isStreaming {
            throw WaxFoundationModelsError.generationInProgress
        }
        isStreaming = true
        var holdsGate = false
        do {
            try await acquireGenerationGateCancellably()
            holdsGate = true
            let stream = try await withGenerationLeaseOwnership {
                try Task.checkCancellation()
                let prepared = try await preparePromptDetailedUngated(for: userPrompt)
                try checkConversationTurnLimit()
                let turn = invocationForTurn(prepared: prepared)
                let inner = generator.streamText(prompt: turn.prompt, options: options)
                let (stream, continuation) = AsyncThrowingStream<WaxGenerationStream.Event, Error>.makeStream()
                let generationPrompt = turn.prompt
                let lease = GenerationLease(gate: generationGate)
                let producer = Task {
                    await self.runStreamingProducer(
                        userPrompt: userPrompt,
                        prepared: prepared,
                        prompt: generationPrompt,
                        options: options,
                        inner: inner,
                        continuation: continuation,
                        lease: lease
                    )
                }
                continuation.onTermination = { _ in
                    producer.cancel()
                }
                return WaxGenerationStream(stream: stream, cancelProducer: { producer.cancel() })
            }
            holdsGate = false
            return stream
        } catch {
            isStreaming = false
            if holdsGate {
                await invalidateAndUnlockGenerationLease()
            }
            throw error
        }
    }

    /// Streams a text response, collects the full assistant text, and persists both sides
    /// of the turn when the session persistence policy allows.
    ///
    /// Consumes ``streamResponse(to:options:)`` so collection shares the owning stream's
    /// persistence and lease semantics.
    @discardableResult
    public func streamResponseAndCollect(
        to userPrompt: String,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> WaxFMResponse<String> {
        try await streamResponse(to: userPrompt, options: options).collect()
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
            configuration: configuration
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
    /// Nonisolated: reads the boxed Apple session so callers can inspect
    /// transcript state without hopping onto the session actor.
    public nonisolated var transcript: Transcript {
        sessionBox.session.transcript
    }

    /// Whether the underlying model is currently generating.
    ///
    /// Nonisolated: reads the boxed Apple session. This is status only; it does
    /// not vend a request handle that could overlap a leased generation.
    public nonisolated var isResponding: Bool {
        sessionBox.session.isResponding
    }

    /// Test seam: tasks parked on ``generationGate``. Used to observe that a
    /// ``streamResponse`` waiter has actually entered the mutex wait.
    package func generationGateWaiterCount() async -> Int {
        await generationGate.waiterCount
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

    /// Acquires ``generationGate`` but returns ``CancellationError`` if the caller
    /// is cancelled while waiting. Cancelled waiters are unregistered by
    /// ``AsyncMutex`` and do not take the lock, so ``isStreaming`` can be cleared
    /// without a sidecar hop.
    private func acquireGenerationGateCancellably() async throws {
        try await generationGate.lock()
    }

    /// FIFO generation lease. Actor isolation is reentrant, so overlapping
    /// `respond`/`streamResponse` calls must not rely on it to keep Apple's
    /// ``LanguageModelSession`` single-flight.
    ///
    /// Nested calls from the task that already owns the *current* lease epoch
    /// reuse it (tools during generate). Independent tasks and unstructured
    /// children holding a stale epoch wait on ``AsyncMutex``.
    private func withGenerationLease<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        if holdsCurrentGenerationLease {
            return try await operation()
        }
        try await generationGate.lock()
        do {
            let value = try await withGenerationLeaseOwnership {
                try await operation()
            }
            await invalidateAndUnlockGenerationLease()
            return value
        } catch {
            await invalidateAndUnlockGenerationLease()
            throw error
        }
    }

    private var holdsCurrentGenerationLease: Bool {
        guard let token = GenerationLeaseOwnership.token else { return false }
        return token.owner == ObjectIdentifier(generationGate)
            && token.epoch == generationLeaseEpoch
    }

    private func withGenerationLeaseOwnership<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        let token = GenerationLeaseOwnership.Token(
            owner: ObjectIdentifier(generationGate),
            epoch: generationLeaseEpoch
        )
        return try await GenerationLeaseOwnership.$token.withValue(token) {
            try await operation()
        }
    }

    /// Invalidate inherited TaskLocal snapshots *before* waking waiters so a
    /// stale child cannot observe the old epoch while the mutex is already free.
    private func invalidateGenerationLeaseToken() {
        generationLeaseEpoch &+= 1
    }

    private func invalidateAndUnlockGenerationLease() async {
        invalidateGenerationLeaseToken()
        await generationGate.unlock()
    }

    /// Produces ``WaxGenerationStream/Event`` values, persists on the stream lifecycle,
    /// and releases the generation lease after the backing Apple request has fully
    /// terminated. Overflow retry (when configured) resets the transcript and consumes
    /// a fresh inner stream once. User persistence still happens only after the first
    /// yielded token of the overall attempt, so a retry after a pre-token overflow
    /// persists on the retry's first token, and a retry after a post-token overflow
    /// does not persist the user turn again.
    private func runStreamingProducer(
        userPrompt: String,
        prepared: PreparedMemoryPrompt,
        prompt: String,
        options: GenerationOptions,
        inner: AsyncThrowingStream<String, Error>,
        continuation: AsyncThrowingStream<WaxGenerationStream.Event, Error>.Continuation,
        lease: GenerationLease
    ) async {
        var lastContent = ""
        var sawContent = false
        var didPersistUser = false
        var currentInner = inner
        var allowOverflowRetry = true

        do {
            streamAttempt: while true {
                do {
                    for try await chunk in currentInner {
                        try Task.checkCancellation()
                        if !sawContent {
                            sawContent = true
                            if configuration.persistencePolicy.shouldPersistUser {
                                didPersistUser = try await persistUserTracked(userPrompt)
                            }
                        }
                        lastContent = chunk
                        continuation.yield(.content(chunk))
                    }
                    break streamAttempt
                } catch {
                    try Task.checkCancellation()
                    let canRetry = allowOverflowRetry
                        && configuration.contextPolicy.overflowPolicy == .resetTranscriptAndRetryOnce
                        && WaxFoundationModelsError.isExceededContextWindow(error)
                        && !resetTranscriptForContext
                    guard canRetry else { throw error }
                    allowOverflowRetry = false
                    resetUnderlyingSessionForContextRetry()
                    currentInner = generator.streamText(prompt: prompt, options: options)
                }
            }

            try Task.checkCancellation()

            var didPersistAssistant = false
            if configuration.persistencePolicy.shouldPersistAssistant {
                didPersistAssistant = try await persistAssistantTracked(lastContent)
            }

            continuation.yield(
                .completed(
                    self.makeResponse(
                        content: lastContent,
                        prepared: prepared,
                        didPersistUser: didPersistUser,
                        didPersistAssistant: didPersistAssistant
                    )
                )
            )
            continuation.finish()
            self.completedTurns += 1
        } catch {
            continuation.finish(
                throwing: self.mapTerminalError(
                    error,
                    prepared: prepared,
                    didPersistUser: didPersistUser
                )
            )
        }

        await generator.joinStream()
        isStreaming = false
        invalidateGenerationLeaseToken()
        await lease.release()
    }

    private func persistTurn(
        userPrompt: String,
        assistantResponse: String,
        prepared: PreparedMemoryPrompt
    ) async throws {
        _ = try await persistTurnTracked(
            userPrompt: userPrompt,
            assistantResponse: assistantResponse,
            prepared: prepared
        )
    }

    private func persistTurnTracked(
        userPrompt: String,
        assistantResponse: String,
        prepared: PreparedMemoryPrompt
    ) async throws -> (didPersistUser: Bool, didPersistAssistant: Bool) {
        // Test seam: the fake can pause here so cancellation lands after the model
        // completed and before either side of the turn is written.
        var didPersistUser = false
        var didPersistAssistant = false
        do {
            try await generator.holdBeforePersistence()
            try Task.checkCancellation()

            if configuration.persistencePolicy.shouldPersistUser {
                didPersistUser = try await persistUserTracked(userPrompt)
            }

            try Task.checkCancellation()

            if configuration.persistencePolicy.shouldPersistAssistant {
                didPersistAssistant = try await persistAssistantTracked(assistantResponse)
            }

            return (didPersistUser, didPersistAssistant)
        } catch {
            throw mapTerminalError(
                error,
                prepared: prepared,
                didPersistUser: didPersistUser,
                didPersistAssistant: didPersistAssistant
            )
        }
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

    @discardableResult
    private func persistAssistantTracked(_ assistantResponse: String) async throws -> Bool {
        let trimmedResponse = assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResponse.isEmpty else { return false }
        try await memory.save(trimmedResponse, metadata: configuration.assistantMetadata)
        return true
    }

    private func makeResponse<Content: Sendable>(
        content: Content,
        prepared: PreparedMemoryPrompt,
        didPersistUser: Bool,
        didPersistAssistant: Bool
    ) -> WaxFMResponse<Content> {
        WaxFMResponse(
            content: content,
            recalledItemCount: prepared.recalledItemCount,
            includedItemCount: prepared.includedItemCount,
            truncatedByBudget: prepared.truncatedByBudget,
            didPersistUser: didPersistUser,
            didPersistAssistant: didPersistAssistant,
            retrievalDiagnostics: prepared.retrievalDiagnostics,
            estimatedPreparedCharacters: prepared.estimatedPreparedCharacters,
            resetTranscriptForContext: consumeResetTranscriptForContext(),
            preparedPromptTokenCount: prepared.preparedPromptTokenCount,
            contextWindowTokens: prepared.contextWindowTokens,
            estimatedContextTokens: prepared.estimatedContextTokens,
            remainingContextTokens: prepared.remainingContextTokens,
            truncationStrategy: prepared.truncationStrategy
        )
    }

    private func consumeResetTranscriptForContext() -> Bool {
        let value = resetTranscriptForContext
        resetTranscriptForContext = false
        return value
    }

    private func mapTerminalError(
        _ error: Error,
        prepared: PreparedMemoryPrompt?,
        didPersistUser: Bool,
        didPersistAssistant: Bool = false
    ) -> Error {
        resetTranscriptForContext = false
        return WaxFoundationModelsError.mapTerminal(
            error,
            estimatedPreparedCharacters: prepared?.estimatedPreparedCharacters ?? 0,
            maxPreparedCharacters: configuration.contextPolicy.maxPreparedCharacters,
            estimatedContextTokens: prepared?.estimatedContextTokens ?? 0,
            measuredPreparedPromptTokenCount: prepared?.preparedPromptTokenCount ?? 0,
            recalledItemCount: prepared?.recalledItemCount ?? 0,
            didPersistUser: didPersistUser,
            didPersistAssistant: didPersistAssistant
        )
    }

    private func throwIfPreparedPromptOverflows(_ prepared: PreparedMemoryPrompt) throws {
        let maxCharacters = configuration.contextPolicy.maxPreparedCharacters
        guard prepared.estimatedPreparedCharacters > maxCharacters else { return }
        throw WaxFoundationModelsError.contextWindowExceeded(
            estimatedPreparedCharacters: prepared.estimatedPreparedCharacters,
            maxPreparedCharacters: maxCharacters,
            estimatedContextTokens: prepared.estimatedContextTokens,
            measuredPreparedPromptTokenCount: prepared.preparedPromptTokenCount,
            recalledItemCount: prepared.recalledItemCount
        )
    }

    private func checkConversationTurnLimit() throws {
        let maxTurns = configuration.contextPolicy.maxConversationTurns
        guard completedTurns >= maxTurns else { return }
        if configuration.contextPolicy.overflowPolicy == .resetTranscriptAndRetryOnce {
            resetUnderlyingSessionForContextRetry()
            return
        }
        throw WaxFoundationModelsError.conversationLimitExceeded(
            completedTurns: completedTurns,
            maxConversationTurns: maxTurns
        )
    }

    private func generateTextHonoringOverflowPolicy(
        prompt: String,
        options: GenerationOptions
    ) async throws -> String {
        try await withOverflowRetry {
            try await self.generator.generateText(prompt: prompt, options: options)
        }
    }

    private func generateStructuredHonoringOverflowPolicy<T: Generable>(
        prompt: String,
        type: T.Type,
        options: GenerationOptions
    ) async throws -> T {
        try await withOverflowRetry {
            try await self.generator.generateStructured(
                prompt: prompt,
                type: type,
                options: options
            )
        }
    }

    private func withOverflowRetry<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            try Task.checkCancellation()
            let canRetry = configuration.contextPolicy.overflowPolicy == .resetTranscriptAndRetryOnce
                && WaxFoundationModelsError.isExceededContextWindow(error)
                && !resetTranscriptForContext
            guard canRetry else { throw error }
            resetUnderlyingSessionForContextRetry()
            return try await operation()
        }
    }

    private func resetUnderlyingSessionForContextRetry() {
        let tools = Self.assembleTools(
            memory: memory,
            additionalTools: additionalTools,
            configuration: configuration
        )
        let resolvedInstructions = Self.defaultInstructions(
            userInstructions: userInstructions,
            includesMemoryTools: configuration.includeMemoryTools,
            toolKit: configuration.toolKit
        )
        let fresh = LanguageModelSession(
            model: model,
            tools: tools,
            instructions: resolvedInstructions
        )
        sessionBox.replace(fresh)
        if generator is LiveLanguageModelGenerator {
            generator = LiveLanguageModelGenerator(session: fresh)
        }
        completedTurns = 0
        resetTranscriptForContext = true
    }

    private static func annotatePreparedPrompt(
        _ prepared: PreparedMemoryPrompt,
        context: RAGContext?,
        finalPrompt: String
    ) async throws -> PreparedMemoryPrompt {
        var annotated = prepared
        annotated.retrievalDiagnostics = context?.diagnostics
        annotated.estimatedPreparedCharacters = finalPrompt.count
        annotated.estimatedContextTokens = context?.totalTokens ?? 0
        annotated.resetTranscriptForContext = false
        annotated.truncationStrategy = prepared.truncatedByBudget ? "characterBudget" : "none"
        annotated.contextWindowTokens = nil
        annotated.remainingContextTokens = nil
        if let counter = try? await TokenCounter.shared() {
            annotated.preparedPromptTokenCount = await counter.count(finalPrompt)
        }
        return annotated
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
    /// This constructor does **not** preflight availability or prewarm the model.
    /// Prefer ``makeFoundationModelsSession(model:instructions:additionalTools:configuration:)``.
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

    /// Preflights Foundation Models availability, then returns a session and prewarms
    /// the underlying ``LanguageModelSession``.
    nonisolated func makeFoundationModelsSession(
        model: SystemLanguageModel = .default,
        instructions: String? = nil,
        additionalTools: [any Tool] = [],
        configuration: FoundationModelsMemorySessionConfig = .default
    ) async throws -> WaxFoundationModelSession {
        try WaxFoundationModelsAvailability.preflight(.current(model: model))
        let session = WaxFoundationModelSession(
            memory: self,
            model: model,
            instructions: instructions,
            additionalTools: additionalTools,
            configuration: configuration
        )
        session.languageModelSession.prewarm()
        return session
    }

    /// Opens a store and returns a memory-backed Foundation Models session that **owns**
    /// the store (``WaxFoundationModelSession/close()`` closes ``Memory``).
    ///
    /// Embedder selection lives on `config.embedding` only. There is no `embedding:`
    /// side-channel; pass ``Memory/EmbeddingSource/custom(_:)`` (or `.builtIn` via the
    /// `builtInEmbedding:` overload) on ``Memory/Config-swift.struct``.
    static func openFoundationModelsSession(
        at url: URL,
        config: Config = .default,
        model: SystemLanguageModel = .default,
        instructions: String? = nil,
        additionalTools: [any Tool] = [],
        sessionConfiguration: FoundationModelsMemorySessionConfig = .default
    ) async throws -> WaxFoundationModelSession {
        try WaxFoundationModelsAvailability.preflight(.current(model: model))
        let memory = try await Memory(at: url, config: config)
        let session = WaxFoundationModelSession(
            memory: memory,
            model: model,
            instructions: instructions,
            additionalTools: additionalTools,
            configuration: sessionConfiguration,
            ownsMemory: true
        )
        session.languageModelSession.prewarm()
        return session
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
        try WaxFoundationModelsAvailability.preflight(.current(model: model))
        var config = config
        config.embedding = .builtIn(builtInEmbedding, embeddingOptions)
        let memory = try await Memory(at: url, config: config)
        let session = WaxFoundationModelSession(
            memory: memory,
            model: model,
            instructions: instructions,
            additionalTools: additionalTools,
            configuration: sessionConfiguration,
            ownsMemory: true
        )
        session.languageModelSession.prewarm()
        return session
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

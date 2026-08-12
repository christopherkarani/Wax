#if canImport(FoundationModels)
import Foundation
import FoundationModels

// MARK: - Result → Foundation Models

@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
extension WaxMemoryToolResult: PromptRepresentable {
    /// Structured tool output for the model (status, action, message, itemCount).
    public var generatedContent: GeneratedContent {
        GeneratedContent(
            properties: [
                "status": status.rawValue,
                "action": action,
                "output": message,
                "itemCount": itemCount,
            ]
        )
    }

    public var promptRepresentation: Prompt {
        // Prefer the human-readable message; structured fields remain available via GeneratedContent.
        Prompt(message)
    }

    /// Decode a structured result from model-visible `GeneratedContent`.
    public init(generatedContent: GeneratedContent) throws {
        let statusRaw: String = try generatedContent.value(String.self, forProperty: "status")
        let action: String = try generatedContent.value(String.self, forProperty: "action")
        let message: String = try generatedContent.value(String.self, forProperty: "output")
        let itemCount: Int = (try? generatedContent.value(Int.self, forProperty: "itemCount")) ?? 0
        guard let status = Status(rawValue: statusRaw) else {
            throw WaxError.decodingError(reason: "invalid WaxMemoryToolResult status: \(statusRaw)")
        }
        self.init(status: status, action: action, message: message, itemCount: itemCount)
    }
}

// MARK: - Combined tool

/// A Foundation Models ``Tool`` that stores and retrieves durable memory via ``Memory``.
///
/// Prefer ``Memory/foundationModelsTools(kit:config:)`` which registers focused tools
/// for higher tool-calling reliability. Use this combined tool when you want a single schema.
///
/// ```swift
/// let memory = try await Memory(at: storeURL)
/// let tools = await memory.foundationModelsTools()
/// let session = LanguageModelSession(tools: tools) {
///     "You have long-term memory. Use waxRemember / waxRecall / waxSearch when needed."
/// }
/// ```
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
public struct WaxMemoryTool: Tool, Sendable {
    public let name: String = "waxMemory"
    public let description: String = """
Manage persistent on-device memory in Wax.
- action=remember (aliases: store, save): store durable facts, preferences, decisions.
- action=recall (aliases: get, lookup): retrieve the best context for a query.
- action=search (aliases: find, query): ranked memory hits with optional topK and hybrid alpha.
- action=forget (aliases: delete, remove, erase): delete matching memory frames for a query.
Do not store secrets or one-off ephemeral chatter.
"""
    public let includesSchemaInInstructions: Bool = true

    private let memory: Memory
    public let config: WaxMemoryToolConfig

    /// Tool arguments produced by Foundation Models guided generation.
    @Generable(description: "Arguments for the combined Wax memory tool.")
    public struct Arguments: Sendable {
        @Guide(
            description: "Action to perform.",
            .anyOf([
                "remember", "recall", "search", "forget",
                "store", "save", "get", "lookup", "find", "query",
                "delete", "remove", "erase",
            ])
        )
        public var action: String

        @Guide(description: "Memory content to store. Required when action is remember/store/save.")
        public var content: String?

        @Guide(description: "Query text. Required when action is recall/search/forget (or get/find/delete).")
        public var query: String?

        @Guide(description: "Optional number of results for search/forget (clamped by tool config).")
        public var topK: Int?

        @Guide(description: "Optional hybrid alpha in [0, 1] for search. Higher favors text search.")
        public var alpha: Float?

        public init(
            action: String = "",
            content: String? = nil,
            query: String? = nil,
            topK: Int? = nil,
            alpha: Float? = nil
        ) {
            self.action = action
            self.content = content
            self.query = query
            self.topK = topK
            self.alpha = alpha
        }
    }

    public init(memory: Memory, config: WaxMemoryToolConfig = .default) {
        self.memory = memory
        self.config = config
    }

    public func call(arguments: Arguments) async throws -> WaxMemoryToolResult {
        await perform(arguments)
    }

    /// Non-throwing entry point that always returns a structured result (errors are status=error).
    public func perform(_ arguments: Arguments) async -> WaxMemoryToolResult {
        await WaxMemoryToolExecutor.execute(
            memory: memory,
            config: config,
            action: arguments.action,
            content: arguments.content,
            query: arguments.query,
            topK: arguments.topK,
            alpha: arguments.alpha
        )
    }
}

// MARK: - Focused tools (preferred for model reliability)

/// Focused tool: store durable memory.
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
public struct WaxRememberTool: Tool, Sendable {
    public let name: String = "waxRemember"
    public let description: String = """
Store a durable fact, preference, or decision in on-device Wax memory.
Use for information that should survive across sessions. Do not store secrets.
"""
    public let includesSchemaInInstructions: Bool = true

    private let memory: Memory
    public let config: WaxMemoryToolConfig

    @Generable(description: "Content to store in Wax memory.")
    public struct Arguments: Sendable {
        @Guide(description: "The durable text to remember.")
        public var content: String

        public init(content: String = "") {
            self.content = content
        }
    }

    public init(memory: Memory, config: WaxMemoryToolConfig = .default) {
        self.memory = memory
        self.config = config
    }

    public func call(arguments: Arguments) async throws -> WaxMemoryToolResult {
        await WaxMemoryToolExecutor.execute(
            memory: memory,
            config: config,
            action: .remember,
            content: arguments.content
        )
    }
}

/// Focused tool: recall assembled memory context for a query.
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
public struct WaxRecallTool: Tool, Sendable {
    public let name: String = "waxRecall"
    public let description: String = """
Recall the most relevant durable memories for a natural-language query.
Use before answering questions about user preferences, past decisions, or prior context.
"""
    public let includesSchemaInInstructions: Bool = true

    private let memory: Memory
    public let config: WaxMemoryToolConfig

    @Generable(description: "Recall query.")
    public struct Arguments: Sendable {
        @Guide(description: "What to look up in memory.")
        public var query: String

        public init(query: String = "") {
            self.query = query
        }
    }

    public init(memory: Memory, config: WaxMemoryToolConfig = .default) {
        self.memory = memory
        self.config = config
    }

    public func call(arguments: Arguments) async throws -> WaxMemoryToolResult {
        await WaxMemoryToolExecutor.execute(
            memory: memory,
            config: config,
            action: .recall,
            query: arguments.query
        )
    }
}

/// Focused tool: ranked memory search hits.
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
public struct WaxSearchTool: Tool, Sendable {
    public let name: String = "waxSearch"
    public let description: String = """
Search durable Wax memory and return ranked hits.
Use when you need broader retrieval or want to control result count via topK.
"""
    public let includesSchemaInInstructions: Bool = true

    private let memory: Memory
    public let config: WaxMemoryToolConfig

    @Generable(description: "Search arguments.")
    public struct Arguments: Sendable {
        @Guide(description: "Search query.")
        public var query: String

        @Guide(description: "Optional max hits (clamped by tool config).")
        public var topK: Int?

        @Guide(description: "Optional hybrid alpha in [0, 1]. Higher favors text search.")
        public var alpha: Float?

        public init(query: String = "", topK: Int? = nil, alpha: Float? = nil) {
            self.query = query
            self.topK = topK
            self.alpha = alpha
        }
    }

    public init(memory: Memory, config: WaxMemoryToolConfig = .default) {
        self.memory = memory
        self.config = config
    }

    public func call(arguments: Arguments) async throws -> WaxMemoryToolResult {
        await WaxMemoryToolExecutor.execute(
            memory: memory,
            config: config,
            action: .search,
            query: arguments.query,
            topK: arguments.topK,
            alpha: arguments.alpha
        )
    }
}

/// Focused tool: forget (delete) matching memory frames by query.
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
public struct WaxForgetTool: Tool, Sendable {
    public let name: String = "waxForget"
    public let description: String = """
Forget durable Wax memory matching a query by deleting up to topK frames.
Use when the user asks to forget, delete, remove, or erase prior stored facts.
"""
    public let includesSchemaInInstructions: Bool = true

    private let memory: Memory
    public let config: WaxMemoryToolConfig

    @Generable(description: "Forget arguments.")
    public struct Arguments: Sendable {
        @Guide(description: "Query describing what to forget.")
        public var query: String

        @Guide(description: "Optional max frames to delete (clamped by tool config forgetTopK/maxSearchTopK).")
        public var topK: Int?

        public init(query: String = "", topK: Int? = nil) {
            self.query = query
            self.topK = topK
        }
    }

    public init(memory: Memory, config: WaxMemoryToolConfig = .default) {
        self.memory = memory
        self.config = config
    }

    public func call(arguments: Arguments) async throws -> WaxMemoryToolResult {
        await WaxMemoryToolExecutor.execute(
            memory: memory,
            config: config,
            action: .forget,
            query: arguments.query,
            topK: arguments.topK
        )
    }
}

// MARK: - Memory factories

@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
public extension Memory {
    /// Creates the combined Foundation Models memory tool.
    ///
    /// Nonisolated: only captures the `Memory` handle; no actor state is read.
    nonisolated func foundationModelsMemoryTool(config: WaxMemoryToolConfig = .default) -> WaxMemoryTool {
        WaxMemoryTool(memory: self, config: config)
    }

    /// Creates a Foundation Models tool set for the given kit.
    ///
    /// - Parameters:
    ///   - kit: Which tool combination to register. Default is ``WaxMemoryToolKit/focused``
    ///     (remember, recall, search) for backward compatibility.
    ///   - config: Shared tool configuration.
    nonisolated func foundationModelsTools(
        kit: WaxMemoryToolKit = .focused,
        config: WaxMemoryToolConfig = .default
    ) -> [any Tool] {
        switch kit {
        case .focused:
            [
                WaxRememberTool(memory: self, config: config),
                WaxRecallTool(memory: self, config: config),
                WaxSearchTool(memory: self, config: config),
            ]
        case .compact:
            [
                WaxRememberTool(memory: self, config: config),
                WaxRecallTool(memory: self, config: config),
            ]
        case .combined:
            [WaxMemoryTool(memory: self, config: config)]
        case .focusedWithForget:
            [
                WaxRememberTool(memory: self, config: config),
                WaxRecallTool(memory: self, config: config),
                WaxSearchTool(memory: self, config: config),
                WaxForgetTool(memory: self, config: config),
            ]
        }
    }

    /// Creates only the combined multi-action tool (legacy single-tool setup).
    nonisolated func foundationModelsCombinedTools(config: WaxMemoryToolConfig = .default) -> [any Tool] {
        foundationModelsTools(kit: .combined, config: config)
    }

    /// Opens a store and returns a Foundation Models memory tool bound to that store.
    static func openFoundationModelsMemoryTool(
        at url: URL,
        config: Config = .default,
        embedding: (any EmbeddingProvider)? = nil,
        toolConfig: WaxMemoryToolConfig = .default
    ) async throws -> WaxMemoryTool {
        var config = config
        if let embedding {
            config.embedding = .custom(embedding)
        }
        let memory = try await Memory(at: url, config: config)
        return WaxMemoryTool(memory: memory, config: toolConfig)
    }
}

// Package-compatible bridge for existing in-module callers that still use MemoryOrchestrator.
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
package extension MemoryOrchestrator {
    func foundationModelsMemoryTool(config: WaxMemoryToolConfig = .default) async -> WaxMemoryTool {
        WaxMemoryTool(memory: Memory(orchestrator: self), config: config)
    }

    static func openFoundationModelsMemoryTool(
        at url: URL,
        config: OrchestratorConfig = .default,
        embedder: (any EmbeddingProvider)? = nil,
        toolConfig: WaxMemoryToolConfig = .default
    ) async throws -> WaxMemoryTool {
        let orchestrator = try await MemoryOrchestrator(at: url, config: config, embedder: embedder)
        return WaxMemoryTool(memory: Memory(orchestrator: orchestrator), config: toolConfig)
    }
}
#endif

import Foundation

/// Preset combinations of Foundation Models memory tools for different model budgets.
///
/// Used by ``Memory/foundationModelsTools(kit:config:)`` when FoundationModels is available.
public enum WaxMemoryToolKit: Sendable, Equatable {
    /// Focused tools: remember, recall, search (default).
    case focused
    /// Minimal set: remember, recall only.
    case compact
    /// Single multi-action combined tool.
    case combined
    /// Focused tools plus forget: remember, recall, search, forget.
    case focusedWithForget
}

/// Supported actions for ``WaxMemoryTool``.
public enum WaxMemoryToolAction: String, Sendable, CaseIterable, Equatable {
    case remember
    case recall
    case search
    case forget

    /// Parses model-produced action text, including common synonyms.
    ///
    /// Accepted forms (case-insensitive, trimmed):
    /// - remember: `remember`, `store`, `save`, `write`, `memorize`
    /// - recall: `recall`, `get`, `retrieve`, `lookup`, `load`
    /// - search: `search`, `find`, `query`, `list`
    /// - forget: `forget`, `delete`, `remove`, `erase`
    public static func parse(_ rawValue: String) -> WaxMemoryToolAction? {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized.isEmpty { return nil }

        if let direct = WaxMemoryToolAction(rawValue: normalized) {
            return direct
        }

        switch normalized {
        case "store", "save", "write", "memorize", "mem":
            return .remember
        case "get", "retrieve", "lookup", "load", "fetch":
            return .recall
        case "find", "query", "list", "hits":
            return .search
        case "delete", "remove", "erase":
            return .forget
        default:
            return nil
        }
    }

    public var canonicalName: String { rawValue }
}

/// How verbose tool result text should be for the model.
public enum WaxMemoryToolResultVerbosity: String, Sendable, Equatable, CaseIterable {
    /// Full item lines (kind/sources/scores/frame ids as applicable).
    case verbose
    /// Shorter item lines for small on-device context windows.
    case compact
}

/// Outcome of a Wax memory tool invocation.
public struct WaxMemoryToolResult: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable, CaseIterable {
        case ok
        case error
    }

    public var status: Status
    public var action: String
    public var message: String
    public var itemCount: Int

    public init(
        status: Status,
        action: String,
        message: String,
        itemCount: Int = 0
    ) {
        self.status = status
        self.action = action
        self.message = message
        self.itemCount = max(0, itemCount)
    }

    public var isSuccess: Bool { status == .ok }

    public static func ok(
        action: WaxMemoryToolAction,
        message: String,
        itemCount: Int = 0
    ) -> WaxMemoryToolResult {
        WaxMemoryToolResult(
            status: .ok,
            action: action.canonicalName,
            message: message,
            itemCount: itemCount
        )
    }

    public static func error(
        action: String,
        message: String,
        itemCount: Int = 0
    ) -> WaxMemoryToolResult {
        WaxMemoryToolResult(
            status: .error,
            action: action,
            message: WaxMemoryToolRenderer.renderError(message),
            itemCount: itemCount
        )
    }
}

/// Configuration for Foundation Models memory tools backed by ``Memory``.
public struct WaxMemoryToolConfig: Sendable, Equatable {
    public var recallMaxItems: Int
    public var searchTopK: Int
    public var maxSearchTopK: Int
    public var searchAlpha: Float
    public var embeddingPolicy: Memory.EmbeddingPolicy
    public var includeScores: Bool
    public var maxItemCharacters: Int
    /// Maximum characters accepted by `remember`. Longer content is rejected with a clear error.
    public var maxContentCharacters: Int
    /// When `embeddingPolicy == .always` and vector search fails, retry with text-only.
    public var fallbackToTextOnVectorFailure: Bool
    public var rememberMetadata: [String: String]
    /// Default number of frames to delete for `forget` (clamped to `maxSearchTopK`).
    public var forgetTopK: Int
    /// Controls length of rendered tool messages.
    public var resultVerbosity: WaxMemoryToolResultVerbosity

    public init(
        recallMaxItems: Int = 6,
        searchTopK: Int = 8,
        maxSearchTopK: Int = 20,
        searchAlpha: Float = 0.5,
        embeddingPolicy: Memory.EmbeddingPolicy = .automatic,
        includeScores: Bool = false,
        maxItemCharacters: Int = 280,
        maxContentCharacters: Int = 8_000,
        fallbackToTextOnVectorFailure: Bool = true,
        rememberMetadata: [String: String] = [
            "wax.channel": "foundation_models",
            "wax.tool": "memory",
        ],
        forgetTopK: Int = 3,
        resultVerbosity: WaxMemoryToolResultVerbosity = .verbose
    ) {
        let clampedMaxTopK = max(1, maxSearchTopK)
        self.maxSearchTopK = clampedMaxTopK
        self.recallMaxItems = max(0, min(recallMaxItems, clampedMaxTopK))
        self.searchTopK = max(1, min(searchTopK, clampedMaxTopK))
        self.searchAlpha = min(1, max(0, searchAlpha))
        self.embeddingPolicy = embeddingPolicy
        self.includeScores = includeScores
        self.maxItemCharacters = max(0, maxItemCharacters)
        self.maxContentCharacters = max(1, maxContentCharacters)
        self.fallbackToTextOnVectorFailure = fallbackToTextOnVectorFailure
        self.rememberMetadata = rememberMetadata
        self.forgetTopK = max(1, min(forgetTopK, clampedMaxTopK))
        self.resultVerbosity = resultVerbosity
    }

    public static let `default` = WaxMemoryToolConfig()

    public func topK(_ requested: Int?) -> Int {
        let fallback = max(1, min(searchTopK, maxSearchTopK))
        guard let requested else { return fallback }
        return max(1, min(requested, maxSearchTopK))
    }

    /// Resolves forget top-K from an optional request, defaulting to ``forgetTopK``.
    public func resolvedForgetTopK(_ requested: Int?) -> Int {
        let fallback = max(1, min(forgetTopK, maxSearchTopK))
        guard let requested else { return fallback }
        return max(1, min(requested, maxSearchTopK))
    }

    public func alpha(_ requested: Float?) -> Float {
        let fallback = max(0, min(searchAlpha, 1))
        guard let requested else { return fallback }
        return max(0, min(requested, 1))
    }

    public func searchOptions(
        topK requestedTopK: Int? = nil,
        alpha requestedAlpha: Float? = nil
    ) -> Memory.SearchOptions {
        let mode: Memory.RetrievalMode = switch embeddingPolicy {
        case .never:
            .textOnly
        case .always:
            .vectorOnly
        case .automatic:
            .hybrid(alpha: alpha(requestedAlpha))
        }
        return Memory.SearchOptions(
            topK: topK(requestedTopK),
            includeSurrogates: false,
            timeRange: nil,
            mode: mode
        )
    }

    public func textOnlySearchOptions(topK requestedTopK: Int? = nil) -> Memory.SearchOptions {
        Memory.SearchOptions(
            topK: topK(requestedTopK),
            includeSurrogates: false,
            timeRange: nil,
            mode: .textOnly
        )
    }
}

/// Renders tool results into concise model-readable text.
public struct WaxMemoryToolRenderer: Sendable {
    public init() {}

    public static func renderError(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty ? "unknown error" : trimmed
        return "Wax memory tool error: \(body)"
    }

    public static func renderRemember(contentLength: Int) -> String {
        "Stored memory (\(max(0, contentLength)) characters)."
    }

    public static func renderForget(query: String, deletedCount: Int) -> String {
        let count = max(0, deletedCount)
        if count == 0 {
            return "No matching memory frames deleted for \"\(query)\"."
        }
        let noun = count == 1 ? "frame" : "frames"
        return "Deleted \(count) memory \(noun) matching \"\(query)\"."
    }

    /// Partial forget failure after some frames were already deleted.
    public static func renderForgetPartial(
        query: String,
        deletedCount: Int,
        failure: String
    ) -> String {
        let count = max(0, deletedCount)
        let noun = count == 1 ? "frame" : "frames"
        let detail = failure.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = detail.isEmpty ? "unknown error" : detail
        return "Partial forget for \"\(query)\": deleted \(count) memory \(noun), then failed: \(body)"
    }

    public static func renderRecall(
        query: String,
        context: RAGContext,
        maxItems: Int,
        includeScores: Bool,
        maxItemCharacters: Int,
        verbosity: WaxMemoryToolResultVerbosity = .verbose
    ) -> String {
        let limitedItems = Array(context.items.prefix(max(0, maxItems)))
        guard !limitedItems.isEmpty else {
            return "No memory context found for \"\(query)\"."
        }

        switch verbosity {
        case .verbose:
            var lines: [String] = ["Memory context for \"\(query)\":"]
            for (index, item) in limitedItems.enumerated() {
                lines.append(
                    formatItemLine(
                        index: index + 1,
                        kind: kindLabel(item.kind),
                        sources: item.sources,
                        score: item.score,
                        text: item.text,
                        includeScores: includeScores,
                        maxItemCharacters: maxItemCharacters,
                        frameId: nil,
                        verbosity: .verbose
                    )
                )
            }

            if context.items.count > limitedItems.count {
                lines.append("… \(context.items.count - limitedItems.count) more memory item(s) omitted.")
            }
            return lines.joined(separator: "\n")

        case .compact:
            var lines: [String] = ["Memory for \"\(query)\":"]
            for (index, item) in limitedItems.enumerated() {
                lines.append(
                    formatItemLine(
                        index: index + 1,
                        kind: nil,
                        sources: item.sources,
                        score: item.score,
                        text: item.text,
                        includeScores: false,
                        maxItemCharacters: maxItemCharacters,
                        frameId: nil,
                        verbosity: .compact
                    )
                )
            }
            return lines.joined(separator: "\n")
        }
    }

    public static func renderSearch(
        query: String,
        items: [RAGContext.Item],
        includeScores: Bool,
        maxItemCharacters: Int,
        verbosity: WaxMemoryToolResultVerbosity = .verbose
    ) -> String {
        guard !items.isEmpty else {
            return "No memory search hits found for \"\(query)\"."
        }

        switch verbosity {
        case .verbose:
            var lines: [String] = ["Memory search hits for \"\(query)\":"]
            for (index, item) in items.enumerated() {
                lines.append(
                    formatItemLine(
                        index: index + 1,
                        kind: nil,
                        sources: item.sources,
                        score: item.score,
                        text: item.text,
                        includeScores: includeScores,
                        maxItemCharacters: maxItemCharacters,
                        frameId: item.frameId,
                        verbosity: .verbose
                    )
                )
            }
            return lines.joined(separator: "\n")

        case .compact:
            var lines: [String] = ["Hits for \"\(query)\":"]
            for (index, item) in items.enumerated() {
                lines.append(
                    formatItemLine(
                        index: index + 1,
                        kind: nil,
                        sources: item.sources,
                        score: item.score,
                        text: item.text,
                        includeScores: false,
                        maxItemCharacters: maxItemCharacters,
                        frameId: nil,
                        verbosity: .compact
                    )
                )
            }
            return lines.joined(separator: "\n")
        }
    }

    public static func truncate(_ text: String, maxCharacters: Int) -> String {
        guard maxCharacters > 0 else { return "" }
        guard text.count > maxCharacters else { return text }
        let truncated = text.prefix(maxCharacters)
        return "\(truncated)…"
    }

    public static func kindLabel(_ kind: RAGContext.ItemKind) -> String {
        switch kind {
        case .snippet:
            return "snippet"
        case .expanded:
            return "expanded"
        case .surrogate:
            return "surrogate"
        }
    }

    private static func formatItemLine(
        index: Int,
        kind: String?,
        sources: [RAGContext.Source],
        score: Float,
        text: String,
        includeScores: Bool,
        maxItemCharacters: Int,
        frameId: UInt64?,
        verbosity: WaxMemoryToolResultVerbosity
    ) -> String {
        let body = truncate(text, maxCharacters: maxItemCharacters)
        switch verbosity {
        case .compact:
            return "\(index). \(body)"
        case .verbose:
            let sourceLabel = sources.map(\.rawValue).joined(separator: ",")
            let scoreLabel = includeScores ? String(format: " score=%.4f", score) : ""
            if let frameId {
                return "\(index). [frame=\(frameId)|\(sourceLabel)\(scoreLabel)] \(body)"
            }
            let kindLabel = kind ?? "item"
            return "\(index). [\(kindLabel)|\(sourceLabel)\(scoreLabel)] \(body)"
        }
    }
}

/// Shared execution path for combined and focused Foundation Models memory tools.
public enum WaxMemoryToolExecutor: Sendable {
    public static func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func execute(
        memory: Memory,
        config: WaxMemoryToolConfig,
        action rawAction: String,
        content: String? = nil,
        query: String? = nil,
        topK: Int? = nil,
        alpha: Float? = nil
    ) async -> WaxMemoryToolResult {
        guard let action = WaxMemoryToolAction.parse(rawAction) else {
            return .error(
                action: rawAction,
                message: "invalid action. Use remember, recall, search, or forget (aliases: store/save, get/lookup, find/query, delete/remove/erase)."
            )
        }
        return await execute(
            memory: memory,
            config: config,
            action: action,
            content: content,
            query: query,
            topK: topK,
            alpha: alpha
        )
    }

    public static func execute(
        memory: Memory,
        config: WaxMemoryToolConfig,
        action: WaxMemoryToolAction,
        content: String? = nil,
        query: String? = nil,
        topK: Int? = nil,
        alpha: Float? = nil
    ) async -> WaxMemoryToolResult {
        do {
            switch action {
            case .remember:
                return try await remember(memory: memory, config: config, content: content)
            case .recall:
                return try await recall(memory: memory, config: config, query: query)
            case .search:
                return try await search(
                    memory: memory,
                    config: config,
                    query: query,
                    topK: topK,
                    alpha: alpha
                )
            case .forget:
                return try await forget(
                    memory: memory,
                    config: config,
                    query: query,
                    topK: topK
                )
            }
        } catch {
            return .error(
                action: action.canonicalName,
                message: "operation failed: \(sanitizedErrorDescription(error))"
            )
        }
    }

    private static func remember(
        memory: Memory,
        config: WaxMemoryToolConfig,
        content: String?
    ) async throws -> WaxMemoryToolResult {
        guard let content = normalizedText(content) else {
            return .error(action: "remember", message: "content is required for action=remember.")
        }
        if content.count > config.maxContentCharacters {
            return .error(
                action: "remember",
                message: "content exceeds maxContentCharacters (\(config.maxContentCharacters))."
            )
        }
        try await memory.save(content, metadata: config.rememberMetadata)
        return .ok(
            action: .remember,
            message: WaxMemoryToolRenderer.renderRemember(contentLength: content.count)
        )
    }

    private static func recall(
        memory: Memory,
        config: WaxMemoryToolConfig,
        query: String?
    ) async throws -> WaxMemoryToolResult {
        guard let query = normalizedText(query) else {
            return .error(action: "recall", message: "query is required for action=recall.")
        }

        let context = try await searchWithFallback(
            memory: memory,
            config: config,
            query: query,
            topK: config.recallMaxItems == 0 ? 1 : config.recallMaxItems,
            alpha: nil
        )
        let message = WaxMemoryToolRenderer.renderRecall(
            query: query,
            context: context,
            maxItems: config.recallMaxItems,
            includeScores: config.includeScores,
            maxItemCharacters: config.maxItemCharacters,
            verbosity: config.resultVerbosity
        )
        let itemCount = min(context.items.count, max(0, config.recallMaxItems))
        return .ok(action: .recall, message: message, itemCount: itemCount)
    }

    private static func search(
        memory: Memory,
        config: WaxMemoryToolConfig,
        query: String?,
        topK: Int?,
        alpha: Float?
    ) async throws -> WaxMemoryToolResult {
        guard let query = normalizedText(query) else {
            return .error(action: "search", message: "query is required for action=search.")
        }

        let resolvedTopK = config.topK(topK)
        let context = try await searchWithFallback(
            memory: memory,
            config: config,
            query: query,
            topK: resolvedTopK,
            alpha: alpha
        )
        let message = WaxMemoryToolRenderer.renderSearch(
            query: query,
            items: context.items,
            includeScores: config.includeScores,
            maxItemCharacters: config.maxItemCharacters,
            verbosity: config.resultVerbosity
        )
        return .ok(action: .search, message: message, itemCount: context.items.count)
    }

    private static func forget(
        memory: Memory,
        config: WaxMemoryToolConfig,
        query: String?,
        topK: Int?
    ) async throws -> WaxMemoryToolResult {
        guard let query = normalizedText(query) else {
            return .error(action: "forget", message: "query is required for action=forget.")
        }

        let resolvedTopK = config.resolvedForgetTopK(topK)
        // Prefer text-only for forget so deletion does not depend on vector availability.
        let context = try await memory.search(
            query,
            options: config.textOnlySearchOptions(topK: resolvedTopK)
        )

        var frameIDs: [UInt64] = []
        var seen = Set<UInt64>()
        for item in context.items {
            guard seen.insert(item.frameId).inserted else { continue }
            frameIDs.append(item.frameId)
        }

        let outcome = await deleteFramesReportingPartial(
            frameIDs: frameIDs,
            delete: { try await memory.delete(frameID: $0) }
        )
        if let failure = outcome.failure {
            return .error(
                action: "forget",
                message: WaxMemoryToolRenderer.renderForgetPartial(
                    query: query,
                    deletedCount: outcome.deleted,
                    failure: sanitizedErrorDescription(failure)
                ),
                itemCount: outcome.deleted
            )
        }

        return .ok(
            action: .forget,
            message: WaxMemoryToolRenderer.renderForget(query: query, deletedCount: outcome.deleted),
            itemCount: outcome.deleted
        )
    }

    /// Deletes frames one-by-one, tracking successful deletes for accurate partial reporting.
    ///
    /// Package-visible so unit tests can inject a throwing `delete` without a live store.
    package static func deleteFramesReportingPartial(
        frameIDs: [UInt64],
        delete: (UInt64) async throws -> Void
    ) async -> (deleted: Int, failure: Error?) {
        var deleted = 0
        for frameID in frameIDs {
            do {
                try await delete(frameID)
                deleted += 1
            } catch {
                return (deleted, error)
            }
        }
        return (deleted, nil)
    }

    /// Search with optional vector→text fallback (shared by tools and session prepare/recall).
    ///
    /// When `fallbackToTextOnVectorFailure` is true and the primary mode uses vectors
    /// (`.always` / `.automatic`), a vector failure retries as text-only. When fallback is
    /// false, failures are thrown (fail closed). ``CancellationError`` is never converted
    /// into a text-fallback success.
    ///
    /// - Parameter embeddingPolicy: When non-`nil`, overrides ``WaxMemoryToolConfig/embeddingPolicy``
    ///   for this search (used by session prepare to honor session-level policy).
    public static func searchWithFallback(
        memory: Memory,
        config: WaxMemoryToolConfig,
        query: String,
        topK: Int,
        alpha: Float? = nil,
        embeddingPolicy: Memory.EmbeddingPolicy? = nil
    ) async throws -> RAGContext {
        var effective = config
        if let embeddingPolicy {
            effective.embeddingPolicy = embeddingPolicy
        }
        let primary = effective.searchOptions(topK: topK, alpha: alpha)
        do {
            return try await memory.search(query, options: primary)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard effective.fallbackToTextOnVectorFailure else { throw error }
            try Task.checkCancellation()
            switch effective.embeddingPolicy {
            case .always, .automatic:
                return try await memory.search(
                    query,
                    options: effective.textOnlySearchOptions(topK: topK)
                )
            case .never:
                throw error
            }
        }
    }

    private static func sanitizedErrorDescription(_ error: Error) -> String {
        let description = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if description.isEmpty {
            return String(describing: type(of: error))
        }
        // Keep tool outputs short for the model context window.
        if description.count > 240 {
            return String(description.prefix(240)) + "…"
        }
        return description
    }
}

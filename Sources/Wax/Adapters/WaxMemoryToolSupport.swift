import Foundation

public enum WaxMemoryToolAction: String, Sendable, CaseIterable, Equatable {
    case remember
    case recall
    case search

    public static func parse(_ rawValue: String) -> WaxMemoryToolAction? {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return WaxMemoryToolAction(rawValue: normalized)
    }
}

public struct WaxMemoryToolConfig: Sendable, Equatable {
    public var recallMaxItems: Int
    public var searchTopK: Int
    public var maxSearchTopK: Int
    public var searchAlpha: Float
    public var queryEmbeddingPolicy: MemoryOrchestrator.QueryEmbeddingPolicy
    public var includeScores: Bool
    public var maxItemCharacters: Int
    public var rememberMetadata: [String: String]

    public init(
        recallMaxItems: Int = 6,
        searchTopK: Int = 8,
        maxSearchTopK: Int = 20,
        searchAlpha: Float = 0.5,
        queryEmbeddingPolicy: MemoryOrchestrator.QueryEmbeddingPolicy = .ifAvailable,
        includeScores: Bool = false,
        maxItemCharacters: Int = 280,
        rememberMetadata: [String: String] = [
            "wax.channel": "foundation_models",
            "wax.tool": "memory",
        ]
    ) {
        self.recallMaxItems = recallMaxItems
        self.searchTopK = searchTopK
        self.maxSearchTopK = maxSearchTopK
        self.searchAlpha = searchAlpha
        self.queryEmbeddingPolicy = queryEmbeddingPolicy
        self.includeScores = includeScores
        self.maxItemCharacters = maxItemCharacters
        self.rememberMetadata = rememberMetadata
    }

    public static let `default` = WaxMemoryToolConfig()

    public func topK(_ requested: Int?) -> Int {
        let fallback = max(1, min(searchTopK, maxSearchTopK))
        guard let requested else { return fallback }
        return max(1, min(requested, maxSearchTopK))
    }

    public func alpha(_ requested: Float?) -> Float {
        let fallback = max(0, min(searchAlpha, 1))
        guard let requested else { return fallback }
        return max(0, min(requested, 1))
    }
}

public struct WaxMemoryToolRenderer: Sendable {
    public init() {}

    public static func renderError(_ message: String) -> String {
        "Wax memory tool error: \(message)"
    }

    public static func renderRemember(contentLength: Int) -> String {
        "Stored memory (\(contentLength) characters)."
    }

    public static func renderRecall(
        query: String,
        context: RAGContext,
        maxItems: Int,
        includeScores: Bool,
        maxItemCharacters: Int
    ) -> String {
        let limitedItems = Array(context.items.prefix(max(0, maxItems)))
        guard !limitedItems.isEmpty else {
            return "No memory context found for \"\(query)\"."
        }

        var lines: [String] = ["Memory context for \"\(query)\":"] 
        for (index, item) in limitedItems.enumerated() {
            let kind = kindLabel(item.kind)
            let sources = item.sources.map(\.rawValue).joined(separator: ",")
            let score = includeScores ? String(format: " score=%.4f", item.score) : ""
            let text = truncate(item.text, maxCharacters: maxItemCharacters)
            lines.append("\(index + 1). [\(kind)|\(sources)\(score)] \(text)")
        }

        if context.items.count > limitedItems.count {
            lines.append("… \(context.items.count - limitedItems.count) more memory item(s) omitted.")
        }
        return lines.joined(separator: "\n")
    }

    public static func renderSearch(
        query: String,
        hits: [MemoryOrchestrator.MemorySearchHit],
        includeScores: Bool,
        maxItemCharacters: Int
    ) -> String {
        guard !hits.isEmpty else {
            return "No memory search hits found for \"\(query)\"."
        }

        var lines: [String] = ["Memory search hits for \"\(query)\":"] 
        for (index, hit) in hits.enumerated() {
            let sources = hit.sources.map(\.rawValue).joined(separator: ",")
            let score = includeScores ? String(format: " score=%.4f", hit.score) : ""
            let preview = truncate(hit.previewText ?? "(no preview)", maxCharacters: maxItemCharacters)
            lines.append("\(index + 1). [frame=\(hit.frameId)|\(sources)\(score)] \(preview)")
        }
        return lines.joined(separator: "\n")
    }

    private static func truncate(_ text: String, maxCharacters: Int) -> String {
        guard maxCharacters > 0 else { return "" }
        guard text.count > maxCharacters else { return text }
        let truncated = text.prefix(maxCharacters)
        return "\(truncated)…"
    }

    private static func kindLabel(_ kind: RAGContext.ItemKind) -> String {
        switch kind {
        case .snippet:
            return "snippet"
        case .expanded:
            return "expanded"
        case .surrogate:
            return "surrogate"
        }
    }
}

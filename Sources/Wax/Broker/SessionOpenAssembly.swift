import Foundation

/// Session-open bootstrap assembly: bounded handoff projection and wire payload.
/// Resume vs start-new stays in ``SessionOpenDecision``. Store I/O stays on the broker.
package enum SessionOpenAssembly {
    package struct Tokenizer: Sendable {
        package var count: @Sendable (String) async -> Int

        package init(count: @escaping @Sendable (String) async -> Int) {
            self.count = count
        }

        /// Test adapter: one token per Character.
        package static let character = Tokenizer(count: { $0.count })
    }

    /// Bound `text` to `maxTokens` while remaining a grapheme prefix of `text`.
    ///
    /// Encode the full string once, then take a proportional character prefix
    /// and shrink by graphemes if that prefix is still over budget.
    package static func tokenLimitedPrefix(
        _ text: String,
        tokenizer: Tokenizer,
        maxTokens: Int
    ) async -> String {
        guard maxTokens > 0, !text.isEmpty else { return "" }
        let fullCount = await tokenizer.count(text)
        if fullCount <= maxTokens { return text }

        let characters = Array(text)
        var high = max(1, min(characters.count, (maxTokens * characters.count) / fullCount))
        var candidate = String(characters.prefix(high))
        var candidateCount = await tokenizer.count(candidate)
        while candidateCount > maxTokens && high > 1 {
            high = max(1, (high * 3) / 4)
            candidate = String(characters.prefix(high))
            candidateCount = await tokenizer.count(candidate)
        }
        return candidateCount <= maxTokens ? candidate : ""
    }

    /// Return a prefix without splitting a user-visible Unicode grapheme.
    package static func utf8Prefix(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var bytes = 0
        var result = String()
        result.reserveCapacity(min(text.utf8.count, maxBytes))
        for character in text {
            let characterBytes = String(character).utf8.count
            guard bytes + characterBytes <= maxBytes else { break }
            result.append(character)
            bytes += characterBytes
        }
        return result
    }

    /// True only when compacting a found handoff that still has content or tasks.
    /// Empty `found=true` bodies hide without a tokenizer, matching the pre-peel early return.
    package static func needsTokenizer(_ value: AgentBrokerValue) -> Bool {
        guard let handoff = value.objectValue,
              handoff["found"]?.boolValue == true
        else {
            return false
        }
        let content = handoff["content"]?.stringValue ?? ""
        let tasks = handoff["pending_tasks"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !tasks.isEmpty
    }

    package static func compactHandoff(
        _ value: AgentBrokerValue,
        recallQuery: String?,
        tokenizer: Tokenizer
    ) async -> AgentBrokerValue {
        guard let handoff = value.objectValue,
              handoff["found"]?.boolValue == true
        else {
            return value
        }

        let originalContent = handoff["content"]?.stringValue ?? ""
        let originalTasks = handoff["pending_tasks"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let trimmedQuery = recallQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let emptyBody = !needsTokenizer(value)
        if emptyBody {
            return .object([
                "found": .bool(false),
                "relevance": .string("low"),
                "content": .string(""),
                "pending_tasks": .array([]),
                "truncated": .bool(false),
                "content_truncated": .bool(false),
                "pending_tasks_truncated": .from(0),
                "pending_tasks_omitted": .from(0),
                "content_bytes": .from(0),
                "content_tokens": .from(0),
            ])
        }
        let lowRelevance = !trimmedQuery.isEmpty
            && MemorySemantics.similarity(lhs: trimmedQuery, rhs: originalContent) < 0.15

        let byteLimitedContent = utf8Prefix(
            originalContent,
            maxBytes: BrokerLimits.maxSessionOpenHandoffContentBytes
        )
        let compactContent = await tokenLimitedPrefix(
            byteLimitedContent,
            tokenizer: tokenizer,
            maxTokens: BrokerLimits.maxSessionOpenHandoffContentTokens
        )
        let contentTruncated = compactContent != originalContent

        let boundedTasks = originalTasks
            .prefix(BrokerLimits.maxSessionOpenPendingTasks)
            .map { task in
                utf8Prefix(task, maxBytes: BrokerLimits.maxSessionOpenPendingTaskBytes)
            }
        let pendingTaskTruncations = zip(
            originalTasks.prefix(BrokerLimits.maxSessionOpenPendingTasks),
            boundedTasks
        ).reduce(into: 0) { count, task in
            if task.0 != task.1 { count += 1 }
        }
        let omittedTaskCount = max(0, originalTasks.count - boundedTasks.count)
        let anyTruncated = contentTruncated || pendingTaskTruncations > 0 || omittedTaskCount > 0
        let contentTokens = await tokenizer.count(compactContent)

        var compact: [String: AgentBrokerValue] = [
            "found": .bool(true),
            "content": .string(compactContent),
            "pending_tasks": .array(boundedTasks.map { .string($0) }),
            "truncated": .bool(anyTruncated),
            "content_truncated": .bool(contentTruncated),
            "pending_tasks_truncated": .from(pendingTaskTruncations),
            "pending_tasks_omitted": .from(omittedTaskCount),
            "content_bytes": .from(compactContent.utf8.count),
            "content_tokens": .from(contentTokens),
        ]
        if lowRelevance {
            compact["relevance"] = .string("low")
        }
        return .object(compact)
    }

    package static func bootstrapPayload(
        sessionID: String,
        rebound: Bool,
        handoff: AgentBrokerValue,
        recall: AgentBrokerValue?
    ) -> AgentBrokerValue {
        let sharePrompt =
            "This MCP connection remembers session_id (\(sessionID)); "
            + "omit it on subsequent memory calls on this connection. "
            + "Retain it for reconnects, explicit cross-session calls, "
            + "and direct broker/CLI use. Host children do not get Wax tools."
        var payload: [String: AgentBrokerValue] = [
            "session_id": .string(sessionID),
            "rebound": .bool(rebound),
            "share_prompt": .string(sharePrompt),
            "handoff": handoff,
        ]
        if let recall {
            payload["recall"] = recall
            if let warning = recall.objectValue?["warning"] {
                payload["warning"] = warning
            }
        }
        return .object(payload)
    }
}

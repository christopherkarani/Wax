import Foundation

package enum AgentBrokerCommandSurface {
    package static let publicCommandArguments: [String: Set<String>] = [
        "memory_append": ["content", "session_id", "metadata", "memory_type", "durability", "project", "repo", "confidence", "expires_in_days", "reviewed", "locked"],
        "memory_search": ["query", "topK", "session_id", "mode", "alpha", "include_working", "include_episodic", "include_durable"],
        "memory_get": ["memory_id"],
        "remember": ["content", "session_id", "metadata", "memory_type", "durability", "project", "repo", "confidence", "expires_in_days", "reviewed", "locked"],
        "recall": ["query", "limit", "session_id", "mode", "alpha", "search_top_k", "topK", "filters"],
        "search": ["query", "mode", "topK", "session_id", "alpha", "filters"],
        "session_synthesize": ["session_id", "minimum_confidence", "minimum_recall_count", "max_candidates"],
        "memory_promote": ["session_id", "frame_id", "content", "metadata", "memory_type", "durability", "project", "repo", "confidence", "expires_in_days", "reviewed", "locked", "approve", "minimum_confidence", "minimum_recall_count", "max_candidates"],
        "promote": ["session_id", "frame_id", "content", "metadata", "memory_type", "durability", "project", "repo", "confidence", "expires_in_days", "reviewed", "locked", "approve", "minimum_confidence", "minimum_recall_count", "max_candidates"],
        "memory_health": [],
        "knowledge_capture": ["content", "metadata", "memory_type", "durability", "project", "repo", "confidence", "reviewed", "locked", "subject", "kind", "aliases", "predicate", "object"],
        "corpus_search": ["query", "rebuild", "recursive", "mode", "alpha", "topK"],
        "flush": [],
        "stats": [],
        "session_start": ["session_id", "agent_id", "run_id"],
        "session_resume": ["session_id", "agent_id", "run_id"],
        "session_end": ["session_id"],
        "handoff": ["content", "session_id", "project", "pending_tasks"],
        "handoff_latest": ["project"],
        "compact_context": ["query", "session_id", "token_budget", "max_items", "mode", "alpha"],
        "markdown_export": ["output_dir", "session_id"],
        "markdown_sync": ["root_dir", "dry_run"],
        "entity_upsert": ["key", "kind", "aliases"],
        "fact_assert": ["subject", "predicate", "object", "relation", "valid_from", "valid_to"],
        "fact_retract": ["fact_id", "at_ms"],
        "facts_query": ["subject", "predicate", "as_of", "limit"],
        "entity_resolve": ["alias", "limit"],
    ]

    private static let controlCommandArguments: [String: Set<String>] = [
        "shutdown": [],
        "exit": [],
        "quit": [],
    ]

    package static let commandArguments: [String: Set<String>] = {
        publicCommandArguments.merging(controlCommandArguments) { publicArguments, _ in
            publicArguments
        }
    }()

    package static func allowedPublicArguments(for command: String) -> Set<String>? {
        publicCommandArguments[command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    package static func allowedArguments(for command: String) -> Set<String>? {
        commandArguments[command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    package static func validateArgumentSurface(
        command: String,
        providedKeys: Set<String>
    ) throws {
        guard let allowed = allowedArguments(for: command) else {
            throw BrokerValidationError.invalid("Unknown broker command '\(command)'.")
        }

        let unknown = providedKeys.subtracting(allowed)
        guard unknown.isEmpty else {
            throw BrokerValidationError.invalid("unsupported argument(s): \(unknown.sorted().joined(separator: ", "))")
        }
    }
}

import Foundation

package enum AgentBrokerCommandSurface {
    package enum Exposure: Sendable, Equatable {
        case publicCommand
        case control
    }

    package struct Entry: Sendable, Equatable {
        package let canonicalName: String
        package let aliases: Set<String>
        package let acceptedArgumentKeys: Set<String>
        package let exposure: Exposure
        package let requiresStructuredMemory: Bool

        package var acceptedNames: Set<String> {
            aliases.union([canonicalName])
        }

        package init(
            canonicalName: String,
            aliases: Set<String> = [],
            acceptedArgumentKeys: Set<String>,
            exposure: Exposure = .publicCommand,
            requiresStructuredMemory: Bool = false
        ) {
            self.canonicalName = canonicalName
            self.aliases = aliases
            self.acceptedArgumentKeys = exposure == .publicCommand
                ? acceptedArgumentKeys.union(["verbosity"])
                : acceptedArgumentKeys
            self.exposure = exposure
            self.requiresStructuredMemory = requiresStructuredMemory
        }
    }

    package static let corpusSearchDefaultRebuild = false

    private static let catalog: [Entry] = [
        Entry(
            canonicalName: "remember",
            aliases: ["memory_append"],
            acceptedArgumentKeys: [
                "content", "session_id", "metadata", "memory_type", "durability", "project", "repo",
                "confidence", "expires_in_days", "reviewed", "locked", "cwd", "scope", "verbosity",
            ]
        ),
        Entry(
            canonicalName: "memory_search",
            acceptedArgumentKeys: [
                "query", "topK", "session_id", "mode", "alpha", "include_working", "include_episodic",
                "include_durable",
            ]
        ),
        Entry(canonicalName: "memory_get", acceptedArgumentKeys: ["memory_id"]),
        Entry(
            canonicalName: "recall",
            acceptedArgumentKeys: [
                "query", "limit", "session_id", "mode", "alpha", "search_top_k", "topK", "filters",
                "project", "repo", "scope", "cwd", "verbosity",
            ]
        ),
        Entry(canonicalName: "search", acceptedArgumentKeys: ["query", "mode", "topK", "session_id", "alpha", "filters"]),
        Entry(canonicalName: "session_synthesize", acceptedArgumentKeys: ["session_id", "minimum_confidence", "minimum_recall_count", "max_candidates"]),
        Entry(canonicalName: "memory_promote", acceptedArgumentKeys: [
            "session_id", "frame_id", "content", "metadata", "memory_type", "durability", "project", "repo",
            "confidence", "expires_in_days", "reviewed", "locked", "approve", "minimum_confidence",
            "minimum_recall_count", "max_candidates",
        ]),
        Entry(canonicalName: "promote", acceptedArgumentKeys: [
            "session_id", "frame_id", "content", "metadata", "memory_type", "durability", "project", "repo",
            "confidence", "expires_in_days", "reviewed", "locked", "approve", "minimum_confidence",
            "minimum_recall_count", "max_candidates",
        ]),
        Entry(canonicalName: "memory_health", acceptedArgumentKeys: []),
        Entry(canonicalName: "knowledge_capture", acceptedArgumentKeys: [
            "content", "session_id", "scope", "metadata", "memory_type", "durability", "project", "repo",
            "confidence", "reviewed", "locked", "subject", "kind", "aliases", "predicate", "object", "cwd",
        ], requiresStructuredMemory: true),
        Entry(canonicalName: "corpus_search", acceptedArgumentKeys: ["query", "rebuild", "recursive", "mode", "alpha", "topK"]),
        Entry(canonicalName: "stats", acceptedArgumentKeys: ["session_id", "verbosity"]),
        Entry(canonicalName: "session_start", acceptedArgumentKeys: ["session_id", "agent_id", "run_id", "cwd", "project", "repo", "verbosity"]),
        Entry(canonicalName: "session_resume", acceptedArgumentKeys: ["session_id", "agent_id", "run_id", "verbosity"]),
        Entry(canonicalName: "session_end", acceptedArgumentKeys: ["session_id", "verbosity"]),
        Entry(canonicalName: "session_close", acceptedArgumentKeys: ["session_id", "content", "project", "pending_tasks", "verbosity"]),
        Entry(canonicalName: "session_open", acceptedArgumentKeys: ["project", "repo", "agent_id", "run_id", "recall_query", "cwd", "verbosity"]),
        Entry(canonicalName: "handoff", acceptedArgumentKeys: ["content", "session_id", "project", "pending_tasks", "verbosity"]),
        Entry(canonicalName: "handoff_latest", acceptedArgumentKeys: ["project", "verbosity"]),
        Entry(canonicalName: "compact_context", acceptedArgumentKeys: ["query", "session_id", "token_budget", "max_items", "mode", "alpha"]),
        Entry(canonicalName: "markdown_export", acceptedArgumentKeys: ["output_dir", "session_id", "project", "all_projects", "cwd"]),
        Entry(canonicalName: "markdown_sync", acceptedArgumentKeys: ["root_dir", "dry_run"]),
        Entry(
            canonicalName: "task_state_migrate",
            acceptedArgumentKeys: ["destination_path", "dry_run", "orphan_policy", "overwrite_destination"]
        ),
        Entry(canonicalName: "entity_upsert", acceptedArgumentKeys: ["key", "kind", "aliases"], requiresStructuredMemory: true),
        Entry(canonicalName: "fact_assert", acceptedArgumentKeys: ["subject", "predicate", "object", "relation", "valid_from", "valid_to", "evidence"], requiresStructuredMemory: true),
        Entry(canonicalName: "fact_retract", acceptedArgumentKeys: ["fact_id", "at_ms"], requiresStructuredMemory: true),
        Entry(canonicalName: "facts_query", acceptedArgumentKeys: ["subject", "predicate", "as_of", "system_as_of", "valid_as_of", "limit"], requiresStructuredMemory: true),
        Entry(canonicalName: "entity_resolve", acceptedArgumentKeys: ["alias", "limit"], requiresStructuredMemory: true),
        Entry(canonicalName: "flush", acceptedArgumentKeys: [], exposure: .control),
        Entry(
            canonicalName: "memory_maintain",
            acceptedArgumentKeys: ["apply", "dry_run", "force_reclaim"],
            exposure: .control
        ),
        Entry(canonicalName: "shutdown", aliases: ["exit", "quit"], acceptedArgumentKeys: [], exposure: .control),
    ]

    private static let lookup: [String: Entry] = {
        var result: [String: Entry] = [:]
        for entry in catalog {
            for name in entry.acceptedNames {
                precondition(result.updateValue(entry, forKey: name) == nil, "Duplicate broker command '\(name)'")
            }
        }
        return result
    }()

    package static var allEntries: [Entry] {
        catalog
    }

    package static var publicEntries: [Entry] {
        catalog.filter { $0.exposure == .publicCommand }
    }

    package static var publicCommandNames: Set<String> {
        Set(publicEntries.flatMap(\.acceptedNames))
    }

    package static let publicCommandArguments: [String: Set<String>] = commandArguments(for: .publicCommand)

    package static let commandArguments: [String: Set<String>] = {
        commandArguments(for: nil)
    }()

    private static func commandArguments(for exposure: Exposure?) -> [String: Set<String>] {
        catalog
            .filter { exposure == nil || $0.exposure == exposure }
            .reduce(into: [String: Set<String>]()) { result, entry in
                for name in entry.acceptedNames {
                    result[name] = entry.acceptedArgumentKeys
                }
            }
    }

    package static func entry(for command: String) -> Entry? {
        lookup[normalize(command)]
    }

    package static func canonicalCommand(for command: String) -> String? {
        entry(for: command)?.canonicalName
    }

    package static func isPublicCommand(_ command: String) -> Bool {
        entry(for: command)?.exposure == .publicCommand
    }

    package static func requiresStructuredMemory(_ command: String) -> Bool {
        entry(for: command)?.requiresStructuredMemory == true
    }

    package static func allowedPublicArguments(for command: String) -> Set<String>? {
        guard let entry = entry(for: command), entry.exposure == .publicCommand else { return nil }
        return entry.acceptedArgumentKeys
    }

    package static func allowedArguments(for command: String) -> Set<String>? {
        entry(for: command)?.acceptedArgumentKeys
    }

    @discardableResult
    package static func validateArgumentSurface(
        command: String,
        providedKeys: Set<String>
    ) throws -> Entry {
        guard let entry = entry(for: command) else {
            throw BrokerValidationError.invalid("Unknown broker command '\(command)'.")
        }

        let unknown = providedKeys.subtracting(entry.acceptedArgumentKeys)
        guard unknown.isEmpty else {
            let valid = entry.acceptedArgumentKeys.sorted().joined(separator: ", ")
            throw BrokerValidationError.invalid(
                "unsupported argument(s): \(unknown.sorted().joined(separator: ", ")); valid argument(s): \(valid)"
            )
        }
        return entry
    }

    private static func normalize(_ command: String) -> String {
        command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

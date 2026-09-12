import Foundation

/// Single command catalog: names, aliases, argument shapes, surface validation,
/// profile views, and host schema derivation.
///
/// This module owns every fact about a broker command. `BrokerCommand.decode`
/// and the MCP pre-check invoke the same `validateArgumentSurface`, and
/// `ToolSchemas` derives host schemas from these entries instead of
/// hand-mirroring them.
package enum BrokerCommandCatalog {
    package enum Exposure: Sendable, Equatable {
        case publicCommand
        case control
    }

    /// Named listing views. Membership is catalog data; the `WAX_MCP_TOOLS`
    /// env reader in the MCP server only selects one of these.
    package enum Profile: String, Sendable, CaseIterable {
        case daily
        case legacy
        case full

        /// Tool names in listing order.
        package var toolNames: [String] {
            switch self {
            case .daily:
                return ["remember", "recall", "stats"]
            case .legacy:
                return [
                    "session_open",
                    "remember",
                    "recall",
                    "session_close",
                    "stats",
                    "memory_get",
                    "compact_context",
                    "session_resume",
                ]
            case .full:
                return []
            }
        }
    }

    package struct Argument: Sendable, Equatable {
        package enum Kind: String, Sendable, Equatable {
            case string
            case integer
            case number
            case boolean
            case stringArray
            case integerArray
        case metadataMap
        case filters
        case factValue
        case freeform
        case evidenceArray
        }

        package let name: String
        package let kind: Kind
        package let required: Bool
        package let description: String?
        package let enumValues: [String]
        package let minimumInt: Int?
        package let maximumInt: Int?
        package let minimumDouble: Double?
        package let maximumDouble: Double?
        package let maxLength: Int?

        package init(
            _ name: String,
            _ kind: Kind,
            required: Bool = false,
            description: String? = nil,
            enumValues: [String] = [],
            minimumInt: Int? = nil,
            maximumInt: Int? = nil,
            minimumDouble: Double? = nil,
            maximumDouble: Double? = nil,
            maxLength: Int? = nil
        ) {
            self.name = name
            self.kind = kind
            self.required = required
            self.description = description
            self.enumValues = enumValues
            self.minimumInt = minimumInt
            self.maximumInt = maximumInt
            self.minimumDouble = minimumDouble
            self.maximumDouble = maximumDouble
            self.maxLength = maxLength
        }
    }

    package struct Entry: Sendable, Equatable {
        package let canonicalName: String
        package let aliases: Set<String>
        package let summary: String
        package let arguments: [Argument]
        package let exposure: Exposure
        package let requiresStructuredMemory: Bool

        package var acceptedNames: Set<String> {
            aliases.union([canonicalName])
        }

        /// Accepted wire keys. `verbosity` is accepted on every public command
        /// without being declared per entry.
        package var acceptedArgumentKeys: Set<String> {
            let keys = Set(arguments.map(\.name))
            return exposure == .publicCommand ? keys.union(["verbosity"]) : keys
        }

        package var requiredArgumentNames: [String] {
            arguments.filter(\.required).map(\.name)
        }

        package init(
            canonicalName: String,
            aliases: Set<String> = [],
            summary: String,
            arguments: [Argument],
            exposure: Exposure = .publicCommand,
            requiresStructuredMemory: Bool = false
        ) {
            self.canonicalName = canonicalName
            self.aliases = aliases
            self.summary = summary
            self.arguments = arguments
            self.exposure = exposure
            self.requiresStructuredMemory = requiresStructuredMemory
        }
    }

    /// One host-listing row. Alias rows (`memory_append`, `promote`) carry
    /// their own summary while sharing the canonical entry's arguments.
    package struct ToolRow: Sendable, Equatable {
        package let name: String
        package let summary: String
        package let entry: Entry

        package init(name: String, summary: String, entry: Entry) {
            self.name = name
            self.summary = summary
            self.entry = entry
        }
    }

    package static let corpusSearchDefaultRebuild = false

    // MARK: - Catalog

    private static let sessionID = Argument(
        "session_id", .string,
        description: "Optional session UUID to scope this write explicitly. metadata.session_id is rejected."
    )

    private static let cwd = Argument(
        "cwd", .string,
        description: "Optional client working directory used to infer project/repo when not explicit. Never the MCP server process cwd."
    )

    private static let project = Argument(
        "project", .string,
        description: "Optional explicit project scope. Defaults to inferred repo/project when available."
    )

    private static let repo = Argument(
        "repo", .string,
        description: "Optional explicit repo scope. Defaults to the current repo when available."
    )

    private static let hybridAlpha = Argument(
        "alpha", .number,
        description: "Optional hybrid alpha in [0,1]. Only valid when mode=hybrid.",
        minimumDouble: 0.0, maximumDouble: 1.0
    )

    private static let retrievalMode = Argument(
        "mode", .string,
        description: "Optional search mode override for recall retrieval.",
        enumValues: ["text", "vector", "hybrid"]
    )

    private static let bareRetrievalMode = Argument("mode", .string, enumValues: ["text", "vector", "hybrid"])
    private static let bareAlpha = Argument("alpha", .number, minimumDouble: 0.0, maximumDouble: 1.0)

    private static let confidence = Argument(
        "confidence", .number,
        description: "Optional confidence score in [0,1] for this memory.",
        minimumDouble: 0.0, maximumDouble: 1.0
    )

    private static let bareConfidence = Argument(
        "confidence", .number, minimumDouble: 0.0, maximumDouble: 1.0
    )

    private static let expiresInDays = Argument(
        "expires_in_days", .integer,
        description: "Optional relative expiry for ephemeral/working memories.",
        minimumInt: 1, maximumInt: 3650
    )

    private static let bareExpiresInDays = Argument(
        "expires_in_days", .integer, minimumInt: 1, maximumInt: 3650
    )

    private static let memoryTypeArg = Argument(
        "memory_type", .string,
        description: "Optional first-class memory type.",
        enumValues: MemoryType.allCases.map(\.rawValue)
    )

    private static let durabilityArg = Argument(
        "durability", .string,
        description: "Optional durability policy.",
        enumValues: MemoryDurability.allCases.map(\.rawValue)
    )

    private static let pendingTasks = Argument(
        "pending_tasks", .stringArray,
        description: "Optional list of pending tasks."
    )

    private static func promotionThresholds(maxCandidatesDescription: String) -> [Argument] {
        [
            Argument(
                "minimum_confidence", .number,
                description: "Optional OpenClaw promotion confidence threshold override in [0,1].",
                minimumDouble: 0.0, maximumDouble: 1.0
            ),
            Argument(
                "minimum_recall_count", .integer,
                description: "Optional minimum recall count for non-canonical promotion candidates.",
                minimumInt: 0
            ),
            Argument(
                "max_candidates", .integer,
                description: maxCandidatesDescription,
                minimumInt: 1, maximumInt: BrokerPromotionSettings.maxCandidateLimit
            ),
        ]
    }

    private static let promoteArguments: [Argument] = [
        Argument(
            "session_id", .string,
            description: "Optional active session UUID used to source a candidate when content is omitted."
        ),
        Argument(
            "frame_id", .integer,
            description: "Optional session frame id to promote from.",
            minimumInt: 0
        ),
        Argument(
            "content", .string,
            description: "Optional explicit content to review/promote instead of sourcing from a session frame."
        ),
        Argument(
            "metadata", .metadataMap,
            description: "Optional metadata overrides for the promoted memory."
        ),
        Argument(
            "memory_type", .string,
            description: "Optional explicit target memory type.",
            enumValues: MemoryType.allCases.map(\.rawValue)
        ),
        Argument(
            "durability", .string,
            description: "Optional target durability override.",
            enumValues: MemoryDurability.allCases.map(\.rawValue)
        ),
        Argument("project", .string),
        Argument("repo", .string),
        bareConfidence,
        bareExpiresInDays,
        Argument("reviewed", .boolean),
        Argument("locked", .boolean),
        Argument(
            "approve", .boolean,
            description: "When true, write the reviewed proposal into durable long-term memory."
        ),
    ] + promotionThresholds(maxCandidatesDescription: "Optional maximum number of durable candidates to surface in related synthesis flows.")

    private static let catalog: [Entry] = [
        Entry(
            canonicalName: "remember",
            aliases: ["memory_append"],
            summary: "Store concise text memory. memory_type selects working or durable storage. The MCP connection supplies session_id after session_open; explicit IDs belong at the top level, never in metadata.",
            arguments: [
                Argument(
                    "content", .string, required: true,
                    description: "Text content to store in memory.",
                    maxLength: AgentBrokerService.maxContentBytes
                ),
                sessionID,
                Argument(
                    "scope", .string,
                    description: "Write horizon. session requires session_id (inherited after session_open); durable forbids session_id. When omitted, memory_type selects the horizon and the connection session supplies project attribution.",
                    enumValues: ["session", "durable"]
                ),
                Argument(
                    "metadata", .metadataMap,
                    description: "Optional metadata map. Scalar values are coerced to strings."
                ),
                memoryTypeArg,
                durabilityArg,
                project,
                repo,
                confidence,
                expiresInDays,
                Argument("reviewed", .boolean, description: "Mark this durable memory as reviewed."),
                Argument("locked", .boolean, description: "Lock this memory as durable and protected from freshness decay."),
                cwd,
            ]
        ),
        Entry(
            canonicalName: "memory_search",
            summary: "Search working, episodic, and durable memory horizons with stable memory IDs for follow-up reads.",
            arguments: [
                Argument("query", .string, required: true, description: "Search query text."),
                Argument("topK", .integer, description: "Max hit count. Default: 10.", minimumInt: 1, maximumInt: 200),
                Argument("session_id", .string, description: "Optional active session UUID for current working-memory retrieval."),
                bareRetrievalMode,
                bareAlpha,
                Argument("include_working", .boolean),
                Argument("include_episodic", .boolean),
                Argument("include_durable", .boolean),
            ]
        ),
        Entry(
            canonicalName: "memory_get",
            summary: "Read a specific memory item by stable memory_id returned from memory_search or compact_context.",
            arguments: [
                Argument(
                    "memory_id", .string, required: true,
                    description: "Stable memory reference returned by memory_search or compact_context."
                ),
            ]
        ),
        Entry(
            canonicalName: "recall",
            summary: "Preferred read path: assemble RAG context for a query. Call after session_open when answering from memory. Omit mode unless you need an override. Default scope is the current project after project/repo resolution; pass scope=global only for intentional cross-project retrieval. Optional session_id merges that session with durable long-term memory under the selected scope.",
            arguments: [
                Argument("query", .string, required: true, description: "Recall query text."),
                Argument(
                    "limit", .integer,
                    description: "Max context items to include. Default: 5.",
                    minimumInt: 1, maximumInt: 100
                ),
                Argument(
                    "session_id", .string,
                    description: "Optional session UUID. When set with default project scope, recall merges that session with durable long-term memory. Omit it unless you already have a broker-issued value — do not invent one."
                ),
                Argument(
                    "project", .string,
                    description: "Optional project hard-filter. Default scope=project keeps only frames with matching wax.project."
                ),
                Argument(
                    "repo", .string,
                    description: "Optional exact wax.repo hard-filter. When project is also set, both filters must match."
                ),
                Argument(
                    "scope", .string,
                    description: "Recall scope. project (default) hard-filters to the resolved project/repo; session skips durable merge when a session_id is supplied; global searches the complete trusted local store without current-project boost (it is not an authorization boundary).",
                    enumValues: ["project", "session", "global"]
                ),
                Argument(
                    "memory_types", .stringArray,
                    description: "Optional hard-filter to these memory_type values (e.g. user_preference for person-lane global recall).",
                    enumValues: MemoryType.allCases.map(\.rawValue)
                ),
                retrievalMode,
                hybridAlpha,
                Argument(
                    "search_top_k", .integer,
                    description: "Optional retrieval top-k for recall search stage. Defaults to limit. Legacy alias: topK.",
                    minimumInt: 1, maximumInt: 200
                ),
                Argument(
                    "topK", .integer,
                    description: "Deprecated legacy alias for search_top_k.",
                    minimumInt: 1, maximumInt: 200
                ),
                cwd,
                Argument("filters", .filters),
            ]
        ),
        Entry(
            canonicalName: "search",
            summary: "Raw ranked search hits (not assembled RAG). Omit mode unless you need an override; hybrid is the default. Exact identifiers still use the lexical lane.",
            arguments: [
                Argument("query", .string, required: true, description: "Search query text."),
                Argument("mode", .string, description: "Search mode.", enumValues: ["text", "vector", "hybrid"]),
                Argument("topK", .integer, description: "Max hit count. Default: 10.", minimumInt: 1, maximumInt: 200),
                Argument(
                    "session_id", .string,
                    description: "Optional session UUID. When set, search merges that session's working store with durable long-term memory in the session's project (same default merge as recall). Omit it to search long-term only."
                ),
                hybridAlpha,
                Argument("filters", .filters),
            ]
        ),
        Entry(
            canonicalName: "session_synthesize",
            summary: "Summarize an active broker-managed session into handoff, lessons, decisions, and promotion candidates.",
            arguments: [
                Argument(
                    "session_id", .string,
                    description: "Optional active session UUID. Required when more than one session is active."
                ),
            ] + promotionThresholds(maxCandidatesDescription: "Optional maximum number of durable candidates to surface.")
        ),
        Entry(
            canonicalName: "memory_promote",
            summary: "Review and optionally promote a session memory into durable long-term memory with dedupe and confidence.",
            arguments: promoteArguments
        ),
        Entry(
            canonicalName: "promote",
            summary: "OpenClaw-compatible alias for durable promotion; writes approved durable memory by default.",
            arguments: promoteArguments
        ),
        Entry(
            canonicalName: "memory_health",
            summary: "Inspect long-term memory quality including stale items, duplicates, and contradiction signals.",
            arguments: []
        ),
        Entry(
            canonicalName: "knowledge_capture",
            summary: "Capture durable knowledge from a natural statement and optionally upsert related entity/fact records.",
            arguments: [
                Argument(
                    "content", .string, required: true,
                    description: "Natural-language durable knowledge to store.",
                    maxLength: AgentBrokerService.maxContentBytes
                ),
                Argument(
                    "session_id", .string,
                    description: "Optional active session UUID for session-local task_state or working knowledge."
                ),
                Argument(
                    "scope", .string,
                    description: "Write horizon. session requires session_id; durable forbids session_id.",
                    enumValues: ["session", "durable"]
                ),
                Argument(
                    "metadata", .metadataMap,
                    description: "Optional metadata map. Scalar values are coerced to strings."
                ),
                Argument("memory_type", .string, enumValues: MemoryType.allCases.map(\.rawValue)),
                Argument("durability", .string, enumValues: MemoryDurability.allCases.map(\.rawValue)),
                Argument("project", .string),
                Argument("repo", .string),
                bareConfidence,
                Argument("reviewed", .boolean),
                Argument("locked", .boolean),
                Argument("subject", .string, description: "Optional entity key to upsert or assert facts against."),
                Argument("kind", .string, description: "Optional entity kind for subject upsert."),
                Argument("aliases", .stringArray),
                Argument("predicate", .string, description: "Optional predicate key for a structured fact assertion."),
                Argument(
                    "object", .freeform,
                    description: "Optional fact object. May be a scalar or a typed object like {\"entity\": \"project:wax\"}."
                ),
                Argument(
                    "cwd", .string,
                    description: "Optional client working directory used to infer project/repo when not explicit."
                ),
            ],
            requiresStructuredMemory: true
        ),
        Entry(
            canonicalName: "corpus_search",
            summary: "Search broker-managed session history and the long-term store with provenance. Use for cross-session retrieval; cite provenance when results matter.",
            arguments: [
                Argument("query", .string, required: true, description: "Search query text."),
                Argument(
                    "rebuild", .boolean,
                    description: "Rebuild the broker-managed shared corpus before searching. Default: \(corpusSearchDefaultRebuild). Rebuilds automatically when the corpus store is missing."
                ),
                Argument(
                    "recursive", .boolean,
                    description: "Recursively scan broker-managed session stores. Default: true."
                ),
                Argument(
                    "mode", .string,
                    description: "Search mode for the shared corpus.",
                    enumValues: ["text", "vector", "hybrid"]
                ),
                hybridAlpha,
                Argument("topK", .integer, description: "Max hit count. Default: 10.", minimumInt: 1, maximumInt: 200),
                Argument(
                    "expand", .boolean,
                    description: "When true, include full text for every hit. Default: false (top 3 include text; remaining hits keep preview)."
                ),
                Argument(
                    "session_id", .string,
                    description: "Optional session UUID. When set, corpus hits are project-fenced like search. Omit after session_open on this connection."
                ),
            ]
        ),
        Entry(
            canonicalName: "stats",
            summary: "Return Wax runtime and storage stats (health check, embedder identity, vector search status).",
            arguments: [
                Argument(
                    "session_id", .string,
                    description: "Optional session UUID. When omitted, stdio/HTTP inject the calling client session if this connection started one."
                ),
            ]
        ),
        Entry(
            canonicalName: "session_start",
            summary: "Create or reuse a broker-managed virtual session and return session_id. Prefer session_open. The same agent_id+run_id reuses the active session instead of minting a sibling.",
            arguments: [
                Argument("session_id", .string, description: "Optional explicit session UUID. If it already exists, use session_resume instead."),
                Argument("agent_id", .string, description: "Stable agent identifier for long-running runtimes. Combined with run_id, reuses the active session."),
                Argument("run_id", .string, description: "Stable run identifier for the current autonomous run. Combined with agent_id, reuses the active session."),
                Argument("project", .string, description: "Optional project stamped onto the new session manifest (overrides cwd inference)."),
                Argument("repo", .string, description: "Optional repo stamped onto the new session manifest (overrides cwd inference)."),
                Argument("cwd", .string, description: "Optional client working directory used to infer project/repo when not explicit."),
                Argument("conversation_id", .string, description: "Host chat/session id. The unique match is resumed across compaction, reconnect, and close. Grok should pass its session UUID. Omitted or whitespace-only is ignored."),
            ]
        ),
        Entry(
            canonicalName: "session_resume",
            summary: "Resume the connection session when arguments are omitted. After reconnecting, supply the saved session_id or agent/run selectors to resume a persisted session.",
            arguments: [
                Argument("session_id", .string, description: "Optional session UUID to reopen. Omit on a bound MCP connection. After reconnect, call session_open with conversation_id; do not invent a UUID."),
                Argument("agent_id", .string, description: "Optional agent selector when session_id is omitted."),
                Argument("run_id", .string, description: "Optional run selector when session_id is omitted."),
            ]
        ),
        Entry(
            canonicalName: "session_end",
            summary: "End the connection session after handoff. Supply session_id to explicitly select another session or when no connection session is bound.",
            arguments: [
                Argument("session_id", .string, description: "Optional session UUID to end explicitly. Omit after session_open on this connection."),
            ]
        ),
        Entry(
            canonicalName: "session_close",
            summary: "Atomic handoff then session_end for the connection session. Idempotent if the session already ended. Supply session_id to explicitly select another session or when no connection session is bound.",
            arguments: [
                Argument("session_id", .string, description: "Session UUID to close. Omit after session_open on this connection. After reconnect, call session_open with conversation_id; do not invent a UUID."),
                Argument(
                    "content", .string, required: true,
                    description: "Concise handoff state summary stored before ending the session. Put unfinished work in pending_tasks; do not include transcripts or repeat the task list here."
                ),
                Argument("project", .string, description: "Optional project scope for the handoff."),
                pendingTasks,
            ]
        ),
        Entry(
            canonicalName: "session_open",
            summary: "One-shot session open plus optional recall. Returns session_id plus a bounded short handoff projection; optional non-empty recall_query adds capped project-scoped recall. Prefer this combined operation over manually fetching a handoff and starting a session. Use handoff_latest only when you need the complete handoff.",
            arguments: [
                Argument("session_id", .string, description: "Optional explicit session UUID to rebind after a broker hop. Omit it to resolve via conversation_id or agent/run selectors."),
                Argument("project", .string, description: "Optional project for handoff_latest, session manifest stamp, and default recall scope."),
                Argument("repo", .string, description: "Optional repo stamped onto the new session manifest (overrides cwd inference)."),
                Argument("agent_id", .string, description: "Stable agent identifier. Combined with run_id, reuses the active session."),
                Argument("run_id", .string, description: "Stable run identifier for the current autonomous run."),
                Argument("recall_query", .string, description: "Optional non-empty query to run capped project-scoped recall after session_start. Omitted or whitespace-only means no recall."),
                Argument("cwd", .string, description: "Optional client working directory used to infer project/repo when not explicit."),
                Argument("conversation_id", .string, description: "Host chat/session id. The unique match is resumed across compaction, reconnect, and close. Grok should pass its session UUID. Omitted or whitespace-only is ignored."),
            ]
        ),
        Entry(
            canonicalName: "handoff",
            summary: "Store an end-of-session handoff note (content, optional project/pending_tasks/session_id) for the next session.",
            arguments: [
                Argument(
                    "content", .string, required: true,
                    description: "Concise state summary for the next session. Put unfinished work in pending_tasks; do not include transcripts or repeat the task list here."
                ),
                Argument("session_id", .string, description: "Optional session UUID to scope this handoff explicitly."),
                Argument("project", .string, description: "Optional project scope."),
                pendingTasks,
            ]
        ),
        Entry(
            canonicalName: "handoff_latest",
            summary: "Fetch the latest handoff note (optional project). Not the default session open — prefer session_open.",
            arguments: [
                Argument("project", .string, description: "Optional project scope for lookup."),
            ]
        ),
        Entry(
            canonicalName: "compact_context",
            summary: "Assemble short, medium, and long-horizon memory into a token-budgeted checkpoint for long-running agents.",
            arguments: [
                Argument("query", .string, required: true, description: "Context assembly query or task summary."),
                Argument("session_id", .string, description: "Optional active session UUID."),
                Argument("token_budget", .integer, minimumInt: 128, maximumInt: 32000),
                Argument("max_items", .integer, minimumInt: 1, maximumInt: 64),
                bareRetrievalMode,
                bareAlpha,
            ]
        ),
        Entry(
            canonicalName: "markdown_export",
            summary: "Export Markdown compatibility projections like MEMORY.md, daily notes, and handoff summaries from Wax state.",
            arguments: [
                Argument("output_dir", .string, required: true, description: "Directory where Markdown projections should be written."),
                Argument("session_id", .string, description: "Optional session UUID to constrain daily-note export scope."),
                Argument(
                    "project", .string,
                    description: "Optional project filter. Defaults to the inferred client or session project when present."
                ),
                Argument(
                    "all_projects", .boolean,
                    description: "When true, export every project. Required for an unfiltered dump when a project can be inferred."
                ),
            ]
        ),
        Entry(
            canonicalName: "markdown_sync",
            summary: "Import and reconcile managed Markdown projections like MEMORY.md, daily notes, and DREAMS.md back into Wax.",
            arguments: [
                Argument("root_dir", .string, required: true, description: "Projection root containing MEMORY.md and the memory/ directory to import from."),
                Argument("dry_run", .boolean, description: "When true, report projected create/update/delete counts without mutating Wax state."),
            ]
        ),
        Entry(
            canonicalName: "task_state_migrate",
            summary: "Copy the long-term store into a distinct destination while repairing legacy durable task_state frames; reports source preservation and deep verification.",
            arguments: [
                Argument(
                    "destination_path", .string, required: true,
                    description: "Distinct destination .wax path for the repaired copy. The source store is never overwritten."
                ),
                Argument(
                    "dry_run", .boolean,
                    description: "Report the planned rehome/quarantine/drop counts without creating the destination."
                ),
                Argument(
                    "orphan_policy", .string,
                    description: "How task_state frames without valid session provenance are handled. Default: quarantine.",
                    enumValues: ["quarantine", "drop"]
                ),
                Argument(
                    "overwrite_destination", .boolean,
                    description: "Allow replacing an existing destination when its migration manifest does not match. Default: false."
                ),
            ]
        ),
        Entry(
            canonicalName: "entity_upsert",
            summary: "Upsert a stable structured-memory entity by key. Use for durable graph nodes, not transient debug notes.",
            arguments: [
                Argument("key", .string, required: true, description: "Entity key, e.g. namespace:id."),
                Argument("kind", .string, required: true, description: "Entity kind."),
                Argument("aliases", .stringArray, description: "Optional aliases for entity resolution."),
            ],
            requiresStructuredMemory: true
        ),
        Entry(
            canonicalName: "fact_assert",
            summary: "Assert a structured-memory fact that can later be retracted. Prefer over free-text remember for stable true/false relations.",
            arguments: [
                Argument("subject", .string, required: true, description: "Subject entity key."),
                Argument("predicate", .string, required: true, description: "Predicate key."),
                Argument(
                    "object", .factValue, required: true,
                    description: "Fact object value: primitive or typed object (entity, time_ms, data_base64)."
                ),
                Argument(
                    "relation", .string,
                    description: "Version relation for this assertion.",
                    enumValues: ["sets", "updates", "extends", "retracts"]
                ),
                Argument("valid_from", .integer, description: "Optional valid-from timestamp (ms since epoch)."),
                Argument("valid_to", .integer, description: "Optional valid-to timestamp (ms since epoch)."),
                Argument(
                    "evidence", .evidenceArray,
                    description: "Optional provenance evidence for this fact."
                ),
            ],
            requiresStructuredMemory: true
        ),
        Entry(
            canonicalName: "fact_retract",
            summary: "Retract (soft-delete) a structured-memory fact by id when corrected or obsolete.",
            arguments: [
                Argument("fact_id", .integer, required: true, description: "Fact row id to retract."),
                Argument("at_ms", .integer, description: "Optional retraction timestamp in ms since epoch."),
            ],
            requiresStructuredMemory: true
        ),
        Entry(
            canonicalName: "facts_query",
            summary: "Query structured-memory facts for stable knowledge-graph answers.",
            arguments: [
                Argument("subject", .string, description: "Optional subject entity key."),
                Argument("predicate", .string, description: "Optional predicate key."),
                Argument("as_of", .integer, description: "Optional query timestamp in ms since epoch for both system and valid time."),
                Argument("system_as_of", .integer, description: "Optional system-time query timestamp in ms since epoch. Overrides as_of for transaction time."),
                Argument("valid_as_of", .integer, description: "Optional valid-time query timestamp in ms since epoch. Overrides as_of for fact validity time."),
                Argument(
                    "limit", .integer,
                    description: "Maximum facts to return. Default: 20.",
                    minimumInt: 1, maximumInt: 500
                ),
            ],
            requiresStructuredMemory: true
        ),
        Entry(
            canonicalName: "entity_resolve",
            summary: "Resolve structured-memory entities by alias before asserting related facts.",
            arguments: [
                Argument("alias", .string, required: true, description: "Alias to resolve."),
                Argument(
                    "limit", .integer,
                    description: "Maximum matches to return. Default: 10.",
                    minimumInt: 1, maximumInt: BrokerLimits.maxEntityResolveLimit
                ),
            ],
            requiresStructuredMemory: true
        ),
        Entry(
            canonicalName: "flush",
            summary: "Flush pending broker writes.",
            arguments: [],
            exposure: .control
        ),
        Entry(
            canonicalName: "memory_maintain",
            summary: "Run broker store maintenance.",
            arguments: [
                Argument("apply", .boolean),
                Argument("dry_run", .boolean),
                Argument("force_reclaim", .boolean),
            ],
            exposure: .control
        ),
        Entry(
            canonicalName: "shutdown",
            aliases: ["exit", "quit"],
            summary: "Shut down the broker.",
            arguments: [],
            exposure: .control
        ),
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

    // MARK: - Lookup + validation (single validate, both entry points)

    package static var allEntries: [Entry] {
        catalog
    }

    package static var publicEntries: [Entry] {
        catalog.filter { $0.exposure == .publicCommand }
    }

    package static var publicCommandNames: Set<String> {
        Set(publicEntries.flatMap(\.acceptedNames))
    }

    package static let commandArguments: [String: Set<String>] = {
        catalog.reduce(into: [String: Set<String>]()) { result, entry in
            for name in entry.acceptedNames {
                result[name] = entry.acceptedArgumentKeys
            }
        }
    }()

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

    package static func allowedArguments(for command: String) -> Set<String>? {
        entry(for: command)?.acceptedArgumentKeys
    }

    /// Validates the argument surface and returns the canonical command name.
    /// Invoked at both entry points (MCP pre-check and broker decode).
    @discardableResult
    package static func validateArgumentSurface(
        command: String,
        providedKeys: Set<String>
    ) throws -> String {
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
        return entry.canonicalName
    }

    private static func normalize(_ command: String) -> String {
        command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Host listing (profiles are named views on the catalog)

    /// Host-listing rows in `tools/list` order. Alias rows carry their own
    /// summary while sharing the canonical entry's arguments.
    private static let toolOrder: [ToolRow] = {
        func row(_ name: String, summary: String? = nil) -> ToolRow {
            guard let entry = lookup[name] else {
                preconditionFailure("Catalog is missing tool '\(name)'")
            }
            return ToolRow(name: name, summary: summary ?? entry.summary, entry: entry)
        }
        return [
            row(
                "memory_append",
                summary: "OpenClaw-compatible alias for remember that appends memory into Wax as the source of truth."
            ),
            row("memory_search"),
            row("memory_get"),
            row("remember"),
            row("recall"),
            row("search"),
            row("session_synthesize"),
            row("memory_promote"),
            row(
                "promote",
                summary: "OpenClaw-compatible alias for durable promotion; writes approved durable memory by default."
            ),
            row("memory_health"),
            row("corpus_search"),
            row("stats"),
            row("session_start"),
            row("session_resume"),
            row("session_end"),
            row("session_close"),
            row("session_open"),
            row("handoff"),
            row("handoff_latest"),
            row("compact_context"),
            row("markdown_export"),
            row("markdown_sync"),
            row("task_state_migrate"),
            row("knowledge_capture"),
            row("entity_upsert"),
            row("fact_assert"),
            row("fact_retract"),
            row("facts_query"),
            row("entity_resolve"),
        ]
    }()

    package static func toolRows(
        profile: Profile,
        structuredMemoryEnabled: Bool
    ) -> [ToolRow] {
        let gated = toolOrder.filter { row in
            structuredMemoryEnabled || !row.entry.requiresStructuredMemory
        }
        switch profile {
        case .full:
            return gated
        case .daily, .legacy:
            let names = profile.toolNames
            let byName = Dictionary(gated.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            return names.compactMap { byName[$0] }
        }
    }

    // MARK: - Schema derivation (target-neutral trees)

    package static func schema(for entry: Entry) -> AgentBrokerValue {
        var properties: [String: AgentBrokerValue] = [:]
        for argument in entry.arguments {
            properties[argument.name] = schemaFragment(for: argument)
        }
        if entry.exposure == .publicCommand {
            properties["verbosity"] = responseVerbosity
        }
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(entry.requiredArgumentNames.map(AgentBrokerValue.string)),
            "additionalProperties": .bool(false),
        ])
    }

    /// Shared filters fragment, exposed for the schema contract tests.
    package static func schemaFragment(for argument: Argument) -> AgentBrokerValue {
        let description = argument.description.map(AgentBrokerValue.string)
        func withDescription(_ pairs: [(String, AgentBrokerValue)]) -> AgentBrokerValue {
            var dict = Dictionary(uniqueKeysWithValues: pairs)
            if let description {
                dict["description"] = description
            }
            return .object(dict)
        }
        func boundedInt() -> [(String, AgentBrokerValue)] {
            var pairs: [(String, AgentBrokerValue)] = [("type", .string("integer"))]
            if let minimumInt = argument.minimumInt {
                pairs.append(("minimum", .int(Int64(minimumInt))))
            }
            if let maximumInt = argument.maximumInt {
                pairs.append(("maximum", .int(Int64(maximumInt))))
            }
            return pairs
        }
        func boundedNumber() -> [(String, AgentBrokerValue)] {
            var pairs: [(String, AgentBrokerValue)] = [("type", .string("number"))]
            if let minimumDouble = argument.minimumDouble {
                pairs.append(("minimum", .double(minimumDouble)))
            }
            if let maximumDouble = argument.maximumDouble {
                pairs.append(("maximum", .double(maximumDouble)))
            }
            return pairs
        }
        switch argument.kind {
        case .string:
            var pairs: [(String, AgentBrokerValue)] = [("type", .string("string"))]
            if !argument.enumValues.isEmpty {
                pairs.append(("enum", .array(argument.enumValues.map(AgentBrokerValue.string))))
            }
            if let maxLength = argument.maxLength {
                pairs.append(("maxLength", .int(Int64(maxLength))))
            }
            return withDescription(pairs)
        case .integer:
            return withDescription(boundedInt())
        case .number:
            return withDescription(boundedNumber())
        case .boolean:
            return withDescription([("type", .string("boolean"))])
        case .stringArray:
            var items: [(String, AgentBrokerValue)] = [("type", .string("string"))]
            if !argument.enumValues.isEmpty {
                items.append(("enum", .array(argument.enumValues.map(AgentBrokerValue.string))))
            }
            return withDescription([("type", .string("array")), ("items", .object(Dictionary(uniqueKeysWithValues: items)))])
        case .integerArray:
            return withDescription([
                ("type", .string("array")),
                ("items", .object(Dictionary(uniqueKeysWithValues: boundedInt()))),
            ])
        case .metadataMap:
            return withDescription([
                ("type", .string("object")),
                ("additionalProperties", scalarMetadataValue),
            ])
        case .filters:
            return searchFilters
        case .factValue:
            return withDescription([("oneOf", factObjectValue)])
        case .freeform:
            // Description-only shape, matching today's knowledge_capture object.
            return withDescription([])
        case .evidenceArray:
            return withDescription([
                ("type", .string("array")),
                ("items", evidenceItem),
            ])
        }
    }

    private static let scalarMetadataValue: AgentBrokerValue = .object([
        "oneOf": .array([
            .object(["type": .string("string")]),
            .object(["type": .string("number")]),
            .object(["type": .string("boolean")]),
        ]),
    ])

    package static let responseVerbosity: AgentBrokerValue = .object([
        "type": .string("string"),
        "description": .string("Response verbosity. compact (default) returns one JSON text block and omits host store paths. verbose includes operator diagnostics and host store paths in both the JSON text block and structuredContent. Hosts that ignore structuredContent still receive the payload."),
        "enum": .array([.string("compact"), .string("verbose")]),
    ])

    private static let searchFilters: AgentBrokerValue = .object([
        "type": .string("object"),
        "properties": .object([
            "metadata": .object([
                "type": .string("object"),
                "description": .string("Exact metadata entry matches as a flat object, or wrapped as {\"exact\": {...}}. Scalar values are coerced to strings."),
                "oneOf": .array([
                    .object([
                        "type": .string("object"),
                        "additionalProperties": scalarMetadataValue,
                        "not": .object(["required": .array([.string("exact")])]),
                    ]),
                    .object([
                        "type": .string("object"),
                        "properties": .object([
                            "exact": .object([
                                "type": .string("object"),
                                "additionalProperties": scalarMetadataValue,
                            ]),
                        ]),
                        "required": .array([.string("exact")]),
                        "additionalProperties": .bool(false),
                    ]),
                ]),
            ]),
            "labels": .object([
                "type": .string("array"),
                "description": .string("Frame labels that must all be present."),
                "items": .object(["type": .string("string")]),
            ]),
            "time_after_ms": .object([
                "type": .string("integer"),
                "description": .string("Optional inclusive lower bound timestamp (ms since epoch)."),
            ]),
            "time_before_ms": .object([
                "type": .string("integer"),
                "description": .string("Optional exclusive upper bound timestamp (ms since epoch)."),
            ]),
            "include_deleted": .object([
                "type": .string("boolean"),
                "description": .string("Whether deleted frames can be included. Default: false."),
            ]),
            "include_superseded": .object([
                "type": .string("boolean"),
                "description": .string("Whether frames superseded by newer frames can be included. Default: false."),
            ]),
            "include_surrogates": .object([
                "type": .string("boolean"),
                "description": .string("Whether surrogate frames can be included. Default: false."),
            ]),
            "frame_ids": .object([
                "type": .string("array"),
                "description": .string("Optional allow-list of frame IDs to search."),
                "items": .object([
                    "type": .string("integer"),
                    "minimum": .int(0),
                ]),
            ]),
        ]),
        "required": .array([]),
        "additionalProperties": .bool(false),
    ])

    private static let factObjectValue: AgentBrokerValue = .array([
        .object(["type": .string("string")]),
        .object(["type": .string("number")]),
        .object(["type": .string("boolean")]),
        .object([
            "type": .string("object"),
            "properties": .object(["entity": .object(["type": .string("string")])]),
            "required": .array([.string("entity")]),
            "additionalProperties": .bool(false),
        ]),
        .object([
            "type": .string("object"),
            "properties": .object(["time_ms": .object(["type": .string("integer")])]),
            "required": .array([.string("time_ms")]),
            "additionalProperties": .bool(false),
        ]),
        .object([
            "type": .string("object"),
            "properties": .object(["data_base64": .object(["type": .string("string")])]),
            "required": .array([.string("data_base64")]),
            "additionalProperties": .bool(false),
        ]),
        .object([
            "type": .string("object"),
            "properties": .object([
                "type": .object(["type": .string("string"), "enum": .array([.string("entity")])]),
                "value": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("type"), .string("value")]),
            "additionalProperties": .bool(false),
        ]),
        .object([
            "type": .string("object"),
            "properties": .object([
                "type": .object(["type": .string("string"), "enum": .array([.string("time_ms")])]),
                "value": .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("type"), .string("value")]),
            "additionalProperties": .bool(false),
        ]),
        .object([
            "type": .string("object"),
            "properties": .object([
                "type": .object(["type": .string("string"), "enum": .array([.string("data_base64")])]),
                "value": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("type"), .string("value")]),
            "additionalProperties": .bool(false),
        ]),
    ])

    private static let evidenceItem: AgentBrokerValue = .object([
        "type": .string("object"),
        "properties": .object([
            "source_frame_id": .object(["type": .string("integer"), "minimum": .int(0)]),
            "chunk_index": .object(["type": .string("integer"), "minimum": .int(0)]),
            "span_start_utf8": .object(["type": .string("integer"), "minimum": .int(0)]),
            "span_end_utf8": .object(["type": .string("integer"), "minimum": .int(1)]),
            "extractor_id": .object(["type": .string("string")]),
            "extractor_version": .object(["type": .string("string")]),
            "confidence": .object([
                "type": .string("number"), "minimum": .double(0.0), "maximum": .double(1.0),
            ]),
            "asserted_at_ms": .object(["type": .string("integer")]),
        ]),
        "required": .array([
            .string("source_frame_id"), .string("extractor_id"),
            .string("extractor_version"), .string("asserted_at_ms"),
        ]),
        "additionalProperties": .bool(false),
    ])
}

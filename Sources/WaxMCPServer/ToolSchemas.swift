#if MCPServer
import MCP
import Wax

enum ToolSchemas {
    static var allTools: [Tool] {
        tools(structuredMemoryEnabled: true)
    }

    static func tools(structuredMemoryEnabled: Bool) -> [Tool] {
        var tools: [Tool] = [
        Tool(
            name: "memory_append",
            description: "OpenClaw-compatible alias for remember that appends memory into Wax as the source of truth.",
            inputSchema: waxMemoryAppend
        ),
        Tool(
            name: "memory_search",
            description: "Search working, episodic, and durable memory horizons with stable memory IDs for follow-up reads.",
            inputSchema: waxMemorySearch
        ),
        Tool(
            name: "memory_get",
            description: "Read a specific memory item by stable memory_id returned from memory_search or compact_context.",
            inputSchema: waxMemoryGet
        ),
        Tool(
            name: "remember",
            description: "Store concise durable text memory (decisions, preferences, facts). For session-scoped writes pass session_id as a top-level argument — never put session_id inside metadata.",
            inputSchema: waxRemember
        ),
        Tool(
            name: "recall",
            description: "Preferred read path: assemble RAG context for a query. Call after handoff_latest/session_start when answering from memory. Passing session_id merges that session with durable long-term memory.",
            inputSchema: waxRecall
        ),
        Tool(
            name: "search",
            description: "Raw ranked search hits (not assembled RAG). Prefer mode hybrid for semantic retrieval; use mode text for lexical/deterministic lookup.",
            inputSchema: waxSearch
        ),
        Tool(
            name: "session_synthesize",
            description: "Summarize an active broker-managed session into handoff, lessons, decisions, and promotion candidates.",
            inputSchema: waxSessionSynthesize
        ),
        Tool(
            name: "memory_promote",
            description: "Review and optionally promote a session memory into durable long-term memory with dedupe and confidence.",
            inputSchema: waxMemoryPromote
        ),
        Tool(
            name: "promote",
            description: "OpenClaw-compatible alias for durable promotion; writes approved durable memory by default.",
            inputSchema: waxPromote
        ),
        Tool(
            name: "memory_health",
            description: "Inspect long-term memory quality including stale items, duplicates, and contradiction signals.",
            inputSchema: waxMemoryHealth
        ),
        Tool(
            name: "corpus_search",
            description: "Search broker-managed session history and the long-term store with provenance. Use for cross-session retrieval; cite provenance when results matter.",
            inputSchema: waxCorpusSearch
        ),
        Tool(
            name: "stats",
            description: "Return Wax runtime and storage stats (health check, embedder identity, vector search status).",
            inputSchema: waxStats
        ),
        Tool(
            name: "session_start",
            description: "Create a broker-managed virtual session and return session_id. Call after handoff_latest at session start; keep session_id for later tools. The same agent_id+run_id reuses the active session instead of minting a sibling.",
            inputSchema: waxSessionStart
        ),
        Tool(
            name: "session_resume",
            description: "Resume a persisted broker-managed session after restart using session_id or agent/run selectors.",
            inputSchema: waxSessionResume
        ),
        Tool(
            name: "session_end",
            description: "End an active broker-managed virtual session after handoff. Pass session_id when multiple sessions are active.",
            inputSchema: waxSessionEnd
        ),
        Tool(
            name: "session_close",
            description: "Atomic handoff then session_end for one session_id. Idempotent if the session already ended.",
            inputSchema: waxSessionClose
        ),
        Tool(
            name: "session_open",
            description: "Open a session in one call. Returns session_id plus a bounded short handoff projection; optional non-empty recall_query adds capped project-scoped recall. Use handoff_latest for the complete handoff and pending tasks.",
            inputSchema: waxSessionOpen
        ),
        Tool(
            name: "handoff",
            description: "Store an end-of-session handoff note (content, optional project/pending_tasks/session_id) for the next session.",
            inputSchema: waxHandoff
        ),
        Tool(
            name: "handoff_latest",
            description: "Call first at session start: fetch the latest handoff note (optional project) before session_start.",
            inputSchema: waxHandoffLatest
        ),
        Tool(
            name: "compact_context",
            description: "Assemble short, medium, and long-horizon memory into a token-budgeted checkpoint for long-running agents.",
            inputSchema: waxCompactContext
        ),
        Tool(
            name: "markdown_export",
            description: "Export Markdown compatibility projections like MEMORY.md, daily notes, and handoff summaries from Wax state.",
            inputSchema: waxMarkdownExport
        ),
        Tool(
            name: "markdown_sync",
            description: "Import and reconcile managed Markdown projections like MEMORY.md, daily notes, and DREAMS.md back into Wax.",
            inputSchema: waxMarkdownSync
        ),
        Tool(
            name: "task_state_migrate",
            description: "Copy the long-term store into a distinct destination while repairing legacy durable task_state frames; reports source preservation and deep verification.",
            inputSchema: waxTaskStateMigrate
        ),
        ]

        let structuredTools: [Tool] = [
            Tool(
                name: "knowledge_capture",
                description: "Capture durable knowledge from a natural statement and optionally upsert related entity/fact records.",
                inputSchema: waxKnowledgeCapture
            ),
            Tool(
                name: "entity_upsert",
                description: "Upsert a stable structured-memory entity by key. Use for durable graph nodes, not transient debug notes.",
                inputSchema: waxEntityUpsert
            ),
            Tool(
                name: "fact_assert",
                description: "Assert a structured-memory fact that can later be retracted. Prefer over free-text remember for stable true/false relations.",
                inputSchema: waxFactAssert
            ),
            Tool(
                name: "fact_retract",
                description: "Retract (soft-delete) a structured-memory fact by id when corrected or obsolete.",
                inputSchema: waxFactRetract
            ),
            Tool(
                name: "facts_query",
                description: "Query structured-memory facts for stable knowledge-graph answers.",
                inputSchema: waxFactsQuery
            ),
            Tool(
                name: "entity_resolve",
                description: "Resolve structured-memory entities by alias before asserting related facts.",
                inputSchema: waxEntityResolve
            ),
        ]
        tools.append(contentsOf: structuredTools.filter { tool in
            structuredMemoryEnabled || !AgentBrokerCommandSurface.requiresStructuredMemory(tool.name)
        })

        return tools
    }

    static let waxRemember: Value = objectSchema(
        properties: [
            "content": [
                "type": "string",
                "description": "Text content to store in memory.",
                "maxLength": .int(maxContentBytes),
            ],
            "session_id": [
                "type": "string",
                "description": "Optional session UUID to scope this write explicitly. metadata.session_id is rejected.",
            ],
            "scope": [
                "type": "string",
                "description": "Write horizon. session requires session_id; durable forbids session_id. Omit for legacy omit-session_id=durable behavior.",
                "enum": ["session", "durable"],
            ],
            "verbosity": [
                "type": "string",
                "description": "Response verbosity. compact (default) returns one JSON text block; verbose returns narrative text plus structured content.",
                "enum": ["compact", "verbose"],
            ],
            "metadata": [
                "type": "object",
                "description": "Optional metadata map. Scalar values are coerced to strings.",
                "additionalProperties": scalarMetadataValueSchema,
            ],
            "memory_type": [
                "type": "string",
                "description": "Optional first-class memory type.",
                "enum": .array(MemoryType.allCases.map { .string($0.rawValue) }),
            ],
            "durability": [
                "type": "string",
                "description": "Optional durability policy.",
                "enum": .array(MemoryDurability.allCases.map { .string($0.rawValue) }),
            ],
            "project": [
                "type": "string",
                "description": "Optional explicit project scope. Defaults to inferred repo/project when available.",
            ],
            "repo": [
                "type": "string",
                "description": "Optional explicit repo scope. Defaults to the current repo when available.",
            ],
            "confidence": [
                "type": "number",
                "description": "Optional confidence score in [0,1] for this memory.",
                "minimum": 0.0,
                "maximum": 1.0,
            ],
            "expires_in_days": [
                "type": "integer",
                "description": "Optional relative expiry for ephemeral/working memories.",
                "minimum": 1,
                "maximum": 3650,
            ],
            "reviewed": [
                "type": "boolean",
                "description": "Mark this durable memory as reviewed.",
            ],
            "locked": [
                "type": "boolean",
                "description": "Lock this memory as durable and protected from freshness decay.",
            ],
        ],
        required: ["content"]
    )
    static let waxMemoryAppend = waxRemember

    static let waxRecall: Value = objectSchema(
        properties: [
            "query": [
                "type": "string",
                "description": "Recall query text.",
            ],
            "limit": [
                "type": "integer",
                "description": "Max context items to include. Default: 5.",
                "minimum": 1,
                "maximum": 100,
            ],
            "session_id": [
                "type": "string",
                "description": "Optional session UUID. When set with default scope, recall merges that session with durable long-term memory.",
            ],
            "project": [
                "type": "string",
                "description": "Optional project hard-filter. Default scope=project keeps only frames with matching wax.project.",
            ],
            "repo": [
                "type": "string",
                "description": "Optional repo hard-filter used when project is unset. Filters wax.repo exactly.",
            ],
            "scope": [
                "type": "string",
                "description": "Recall scope. project (default) hard-filters to resolved project; session requires session_id and skips durable merge; global disables project filter.",
                "enum": ["project", "session", "global"],
            ],
            "mode": [
                "type": "string",
                "description": "Optional search mode override for recall retrieval.",
                "enum": ["text", "vector", "hybrid"],
            ],
            "alpha": [
                "type": "number",
                "description": "Optional hybrid alpha in [0,1]. Only valid when mode=hybrid.",
                "minimum": 0.0,
                "maximum": 1.0,
            ],
            "search_top_k": [
                "type": "integer",
                "description": "Optional retrieval top-k for recall search stage. Defaults to limit. Legacy alias: topK.",
                "minimum": 1,
                "maximum": 200,
            ],
            "topK": [
                "type": "integer",
                "description": "Deprecated legacy alias for search_top_k.",
                "minimum": 1,
                "maximum": 200,
            ],
            "verbosity": [
                "type": "string",
                "description": "Response verbosity. compact (default) returns one JSON text block; verbose returns narrative text plus structured content.",
                "enum": ["compact", "verbose"],
            ],
            "filters": searchFilters,
        ],
        required: ["query"]
    )

    static let waxSearch: Value = objectSchema(
        properties: [
            "query": [
                "type": "string",
                "description": "Search query text.",
            ],
            "mode": [
                "type": "string",
                "description": "Search mode.",
                "enum": ["text", "vector", "hybrid"],
            ],
            "topK": [
                "type": "integer",
                "description": "Max hit count. Default: 10.",
                "minimum": 1,
                "maximum": 200,
            ],
            "session_id": [
                "type": "string",
                "description": "Optional session UUID for scoped search.",
            ],
            "alpha": [
                "type": "number",
                "description": "Optional hybrid alpha in [0,1]. Only valid when mode=hybrid.",
                "minimum": 0.0,
                "maximum": 1.0,
            ],
            "filters": searchFilters,
        ],
        required: ["query"]
    )
    static let waxMemorySearch: Value = objectSchema(
        properties: [
            "query": ["type": "string", "description": "Search query text."],
            "topK": ["type": "integer", "description": "Max hit count. Default: 10.", "minimum": 1, "maximum": 200],
            "session_id": ["type": "string", "description": "Optional active session UUID for current working-memory retrieval."],
            "mode": ["type": "string", "enum": ["text", "vector", "hybrid"]],
            "alpha": ["type": "number", "minimum": 0.0, "maximum": 1.0],
            "include_working": ["type": "boolean"],
            "include_episodic": ["type": "boolean"],
            "include_durable": ["type": "boolean"],
        ],
        required: ["query"]
    )
    static let waxMemoryGet: Value = objectSchema(
        properties: [
            "memory_id": [
                "type": "string",
                "description": "Stable memory reference returned by memory_search or compact_context.",
            ],
        ],
        required: ["memory_id"]
    )

    static let waxFlush: Value = emptyObjectSchema()
    static let waxStats: Value = objectSchema(
        properties: [
            "session_id": [
                "type": "string",
                "description": "Optional session UUID. When omitted, stdio/HTTP inject the calling client session if this connection started one.",
            ],
            "verbosity": responseVerbositySchema,
        ],
        required: []
    )
    static let waxSessionSynthesize: Value = objectSchema(
        properties: [
            "session_id": [
                "type": "string",
                "description": "Optional active session UUID. Required when more than one session is active.",
            ],
            "minimum_confidence": [
                "type": "number",
                "description": "Optional OpenClaw promotion confidence threshold override in [0,1].",
                "minimum": 0.0,
                "maximum": 1.0,
            ],
            "minimum_recall_count": [
                "type": "integer",
                "description": "Optional minimum recall count for non-canonical promotion candidates.",
                "minimum": 0,
            ],
            "max_candidates": [
                "type": "integer",
                "description": "Optional maximum number of durable candidates to surface.",
                "minimum": 1,
                "maximum": .int(BrokerPromotionSettings.maxCandidateLimit),
            ],
        ],
        required: []
    )
    static let waxMemoryPromote: Value = objectSchema(
        properties: [
            "session_id": [
                "type": "string",
                "description": "Optional active session UUID used to source a candidate when content is omitted.",
            ],
            "frame_id": [
                "type": "integer",
                "description": "Optional session frame id to promote from.",
                "minimum": 0,
            ],
            "content": [
                "type": "string",
                "description": "Optional explicit content to review/promote instead of sourcing from a session frame.",
            ],
            "metadata": [
                "type": "object",
                "description": "Optional metadata overrides for the promoted memory.",
                "additionalProperties": scalarMetadataValueSchema,
            ],
            "memory_type": [
                "type": "string",
                "description": "Optional explicit target memory type.",
                "enum": .array(MemoryType.allCases.map { .string($0.rawValue) }),
            ],
            "durability": [
                "type": "string",
                "description": "Optional target durability override.",
                "enum": .array(MemoryDurability.allCases.map { .string($0.rawValue) }),
            ],
            "project": ["type": "string"],
            "repo": ["type": "string"],
            "confidence": [
                "type": "number",
                "minimum": 0.0,
                "maximum": 1.0,
            ],
            "expires_in_days": [
                "type": "integer",
                "minimum": 1,
                "maximum": 3650,
            ],
            "reviewed": ["type": "boolean"],
            "locked": ["type": "boolean"],
            "approve": [
                "type": "boolean",
                "description": "When true, write the reviewed proposal into durable long-term memory.",
            ],
            "minimum_confidence": [
                "type": "number",
                "description": "Optional OpenClaw promotion confidence threshold override in [0,1].",
                "minimum": 0.0,
                "maximum": 1.0,
            ],
            "minimum_recall_count": [
                "type": "integer",
                "description": "Optional minimum recall count for non-canonical promotion candidates.",
                "minimum": 0,
            ],
            "max_candidates": [
                "type": "integer",
                "description": "Optional maximum number of durable candidates to surface in related synthesis flows.",
                "minimum": 1,
                "maximum": .int(BrokerPromotionSettings.maxCandidateLimit),
            ],
        ],
        required: []
    )
    static let waxPromote = waxMemoryPromote
    static let waxMemoryHealth: Value = emptyObjectSchema()
    static let waxCorpusSearch: Value = objectSchema(
        properties: [
            "query": [
                "type": "string",
                "description": "Search query text.",
            ],
            "rebuild": [
                "type": "boolean",
                "description": "Rebuild the broker-managed shared corpus before searching. Default: \(AgentBrokerCommandSurface.corpusSearchDefaultRebuild). Rebuilds automatically when the corpus store is missing.",
            ],
            "recursive": [
                "type": "boolean",
                "description": "Recursively scan broker-managed session stores. Default: true.",
            ],
            "mode": [
                "type": "string",
                "description": "Search mode for the shared corpus.",
                "enum": ["text", "vector", "hybrid"],
            ],
            "alpha": [
                "type": "number",
                "description": "Optional hybrid alpha in [0,1]. Only valid when mode=hybrid.",
                "minimum": 0.0,
                "maximum": 1.0,
            ],
            "topK": [
                "type": "integer",
                "description": "Max hit count. Default: 10.",
                "minimum": 1,
                "maximum": 200,
            ],
        ],
        required: ["query"]
    )
    static let waxSessionStart: Value = objectSchema(
        properties: [
            "session_id": ["type": "string", "description": "Optional explicit session UUID. If it already exists, use session_resume instead."],
            "agent_id": ["type": "string", "description": "Stable agent identifier for long-running runtimes. Combined with run_id, reuses the active session."],
            "run_id": ["type": "string", "description": "Stable run identifier for the current autonomous run. Combined with agent_id, reuses the active session."],
            "project": ["type": "string", "description": "Optional project stamped onto the new session manifest (overrides cwd inference)."],
            "repo": ["type": "string", "description": "Optional repo stamped onto the new session manifest (overrides cwd inference)."],
            "cwd": ["type": "string", "description": "Optional client working directory used to infer project/repo when not explicit."],
            "verbosity": responseVerbositySchema,
        ],
        required: []
    )
    static let waxSessionResume: Value = objectSchema(
        properties: [
            "session_id": ["type": "string", "description": "Session UUID to reopen."],
            "agent_id": ["type": "string", "description": "Optional agent selector when session_id is omitted."],
            "run_id": ["type": "string", "description": "Optional run selector when session_id is omitted."],
            "verbosity": responseVerbositySchema,
        ],
        required: []
    )
    static let waxSessionEnd: Value = objectSchema(
        properties: [
            "session_id": [
                "type": "string",
                "description": "Optional session UUID to end explicitly. Required when more than one MCP session is active.",
            ],
            "verbosity": responseVerbositySchema,
        ],
        required: []
    )

    static let waxSessionClose: Value = objectSchema(
        properties: [
            "session_id": [
                "type": "string",
                "description": "Session UUID to close (required).",
            ],
            "content": [
                "type": "string",
                "description": "Concise handoff state summary stored before ending the session. Put unfinished work in pending_tasks; do not include transcripts or repeat the task list here.",
            ],
            "project": [
                "type": "string",
                "description": "Optional project scope for the handoff.",
            ],
            "pending_tasks": [
                "type": "array",
                "description": "Optional list of pending tasks.",
                "items": ["type": "string"],
            ],
            "verbosity": responseVerbositySchema,
        ],
        required: ["session_id", "content"]
    )

    static let waxSessionOpen: Value = objectSchema(
        properties: [
            "project": [
                "type": "string",
                "description": "Optional project for handoff_latest, session manifest stamp, and default recall scope.",
            ],
            "repo": [
                "type": "string",
                "description": "Optional repo stamped onto the new session manifest (overrides cwd inference).",
            ],
            "agent_id": [
                "type": "string",
                "description": "Stable agent identifier. Combined with run_id, reuses the active session.",
            ],
            "run_id": [
                "type": "string",
                "description": "Stable run identifier for the current autonomous run.",
            ],
            "recall_query": [
                "type": "string",
                "description": "Optional non-empty query to run capped project-scoped recall after session_start. Omitted or whitespace-only means no recall.",
            ],
            "cwd": [
                "type": "string",
                "description": "Optional client working directory used to infer project/repo when not explicit.",
            ],
            "verbosity": responseVerbositySchema,
        ],
        required: []
    )

    static let waxHandoff: Value = objectSchema(
        properties: [
            "content": [
                "type": "string",
                "description": "Concise state summary for the next session. Put unfinished work in pending_tasks; do not include transcripts or repeat the task list here.",
            ],
            "session_id": [
                "type": "string",
                "description": "Optional session UUID to scope this handoff explicitly.",
            ],
            "project": [
                "type": "string",
                "description": "Optional project scope.",
            ],
            "pending_tasks": [
                "type": "array",
                "description": "Optional list of pending tasks.",
                "items": ["type": "string"],
            ],
            "verbosity": responseVerbositySchema,
        ],
        required: ["content"]
    )

    static let waxKnowledgeCapture: Value = objectSchema(
        properties: [
            "content": [
                "type": "string",
                "description": "Natural-language durable knowledge to store.",
                "maxLength": .int(maxContentBytes),
            ],
            "session_id": [
                "type": "string",
                "description": "Optional active session UUID for session-local task_state or working knowledge.",
            ],
            "scope": [
                "type": "string",
                "description": "Write horizon. session requires session_id; durable forbids session_id.",
                "enum": ["session", "durable"],
            ],
            "metadata": [
                "type": "object",
                "description": "Optional metadata map. Scalar values are coerced to strings.",
                "additionalProperties": scalarMetadataValueSchema,
            ],
            "memory_type": [
                "type": "string",
                "enum": .array(MemoryType.allCases.map { .string($0.rawValue) }),
            ],
            "durability": [
                "type": "string",
                "enum": .array(MemoryDurability.allCases.map { .string($0.rawValue) }),
            ],
            "project": ["type": "string"],
            "repo": ["type": "string"],
            "confidence": [
                "type": "number",
                "minimum": 0.0,
                "maximum": 1.0,
            ],
            "reviewed": ["type": "boolean"],
            "locked": ["type": "boolean"],
            "subject": [
                "type": "string",
                "description": "Optional entity key to upsert or assert facts against.",
            ],
            "kind": [
                "type": "string",
                "description": "Optional entity kind for subject upsert.",
            ],
            "aliases": [
                "type": "array",
                "items": ["type": "string"],
            ],
            "predicate": [
                "type": "string",
                "description": "Optional predicate key for a structured fact assertion.",
            ],
            "object": [
                "description": .string("Optional fact object. May be a scalar or a typed object like {\"entity\": \"project:wax\"}."),
            ],
        ],
        required: ["content"]
    )

    static let searchFilters: Value = objectSchema(
        properties: [
            "metadata": [
                "type": "object",
                "description": "Exact metadata entry matches as a flat object, or wrapped as {\"exact\": {...}}. Scalar values are coerced to strings.",
                "additionalProperties": scalarMetadataValueSchema,
            ],
            "labels": [
                "type": "array",
                "description": "Frame labels that must all be present.",
                "items": ["type": "string"],
            ],
            "time_after_ms": [
                "type": "integer",
                "description": "Optional inclusive lower bound timestamp (ms since epoch).",
            ],
            "time_before_ms": [
                "type": "integer",
                "description": "Optional exclusive upper bound timestamp (ms since epoch).",
            ],
            "include_deleted": [
                "type": "boolean",
                "description": "Whether deleted frames can be included. Default: false.",
            ],
            "include_superseded": [
                "type": "boolean",
                "description": "Whether frames superseded by newer frames can be included. Default: false.",
            ],
            "include_surrogates": [
                "type": "boolean",
                "description": "Whether surrogate frames can be included. Default: false.",
            ],
            "frame_ids": [
                "type": "array",
                "description": "Optional allow-list of frame IDs to search.",
                "items": [
                    "type": "integer",
                    "minimum": 0,
                ],
            ],
        ],
        required: [],
        includeResponseVerbosity: false
    )

    static let waxHandoffLatest: Value = objectSchema(
        properties: [
            "project": [
                "type": "string",
                "description": "Optional project scope for lookup.",
            ],
            "verbosity": responseVerbositySchema,
        ],
        required: []
    )
    static let waxCompactContext: Value = objectSchema(
        properties: [
            "query": ["type": "string", "description": "Context assembly query or task summary."],
            "session_id": ["type": "string", "description": "Optional active session UUID."],
            "token_budget": ["type": "integer", "minimum": 128, "maximum": 32000],
            "max_items": ["type": "integer", "minimum": 1, "maximum": 64],
            "mode": ["type": "string", "enum": ["text", "vector", "hybrid"]],
            "alpha": ["type": "number", "minimum": 0.0, "maximum": 1.0],
        ],
        required: ["query"]
    )
    static let waxMarkdownExport: Value = objectSchema(
        properties: [
            "output_dir": ["type": "string", "description": "Directory where Markdown projections should be written."],
            "session_id": ["type": "string", "description": "Optional session UUID to constrain daily-note export scope."],
            "project": [
                "type": "string",
                "description": "Optional project filter. Defaults to the inferred client or session project when present.",
            ],
            "all_projects": [
                "type": "boolean",
                "description": "When true, export every project. Required for an unfiltered dump when a project can be inferred.",
            ],
        ],
        required: ["output_dir"]
    )
    static let waxMarkdownSync: Value = objectSchema(
        properties: [
            "root_dir": ["type": "string", "description": "Projection root containing MEMORY.md and the memory/ directory to import from."],
            "dry_run": ["type": "boolean", "description": "When true, report projected create/update/delete counts without mutating Wax state."],
        ],
        required: ["root_dir"]
    )
    static let waxTaskStateMigrate: Value = objectSchema(
        properties: [
            "destination_path": [
                "type": "string",
                "description": "Distinct destination .wax path for the repaired copy. The source store is never overwritten.",
            ],
            "dry_run": [
                "type": "boolean",
                "description": "Report the planned rehome/quarantine/drop counts without creating the destination.",
            ],
            "orphan_policy": [
                "type": "string",
                "description": "How task_state frames without valid session provenance are handled. Default: quarantine.",
                "enum": ["quarantine", "drop"],
            ],
            "overwrite_destination": [
                "type": "boolean",
                "description": "Allow replacing an existing destination when its migration manifest does not match. Default: false.",
            ],
        ],
        required: ["destination_path"]
    )

    static let waxEntityUpsert: Value = objectSchema(
        properties: [
            "key": [
                "type": "string",
                "description": "Entity key, e.g. namespace:id.",
            ],
            "kind": [
                "type": "string",
                "description": "Entity kind.",
            ],
            "aliases": [
                "type": "array",
                "description": "Optional aliases for entity resolution.",
                "items": ["type": "string"],
            ],
        ],
        required: ["key", "kind"]
    )

    static let waxFactAssert: Value = objectSchema(
        properties: [
            "subject": [
                "type": "string",
                "description": "Subject entity key.",
            ],
            "predicate": [
                "type": "string",
                "description": "Predicate key.",
            ],
            "object": [
                "oneOf": [
                    ["type": "string"],
                    ["type": "integer"],
                    ["type": "number"],
                    ["type": "boolean"],
                    [
                        "type": "object",
                        "properties": [
                            "entity": ["type": "string"],
                        ],
                        "required": ["entity"],
                        "additionalProperties": false,
                    ],
                    [
                        "type": "object",
                        "properties": [
                            "time_ms": ["type": "integer"],
                        ],
                        "required": ["time_ms"],
                        "additionalProperties": false,
                    ],
                    [
                        "type": "object",
                        "properties": [
                            "data_base64": ["type": "string"],
                        ],
                        "required": ["data_base64"],
                        "additionalProperties": false,
                    ],
                    [
                        "type": "object",
                        "properties": [
                            "type": [
                                "type": "string",
                                "enum": ["entity"],
                            ],
                            "value": [
                                "type": "string",
                            ],
                        ],
                        "required": ["type", "value"],
                        "additionalProperties": false,
                    ],
                    [
                        "type": "object",
                        "properties": [
                            "type": [
                                "type": "string",
                                "enum": ["time_ms"],
                            ],
                            "value": [
                                "type": "integer",
                            ],
                        ],
                        "required": ["type", "value"],
                        "additionalProperties": false,
                    ],
                    [
                        "type": "object",
                        "properties": [
                            "type": [
                                "type": "string",
                                "enum": ["data_base64"],
                            ],
                            "value": [
                                "type": "string",
                            ],
                        ],
                        "required": ["type", "value"],
                        "additionalProperties": false,
                    ],
                ],
                "description": "Fact object value: primitive or typed object (entity, time_ms, data_base64).",
            ],
            "relation": [
                "type": "string",
                "description": "Version relation for this assertion.",
                "enum": ["sets", "updates", "extends", "retracts"],
            ],
            "valid_from": [
                "type": "integer",
                "description": "Optional valid-from timestamp (ms since epoch).",
            ],
            "valid_to": [
                "type": "integer",
                "description": "Optional valid-to timestamp (ms since epoch).",
            ],
            "evidence": [
                "type": "array",
                "description": "Optional provenance evidence for this fact.",
                "items": [
                    "type": "object",
                    "properties": [
                        "source_frame_id": ["type": "integer", "minimum": 0],
                        "chunk_index": ["type": "integer", "minimum": 0],
                        "span_start_utf8": ["type": "integer", "minimum": 0],
                        "span_end_utf8": ["type": "integer", "minimum": 1],
                        "extractor_id": ["type": "string"],
                        "extractor_version": ["type": "string"],
                        "confidence": ["type": "number", "minimum": 0.0, "maximum": 1.0],
                        "asserted_at_ms": ["type": "integer"],
                    ],
                    "required": ["source_frame_id", "extractor_id", "extractor_version", "asserted_at_ms"],
                    "additionalProperties": false,
                ],
            ],
        ],
        required: ["subject", "predicate", "object"]
    )

    static let waxFactRetract: Value = objectSchema(
        properties: [
            "fact_id": [
                "type": "integer",
                "description": "Fact row id to retract.",
            ],
            "at_ms": [
                "type": "integer",
                "description": "Optional retraction timestamp in ms since epoch.",
            ],
        ],
        required: ["fact_id"]
    )

    static let waxFactsQuery: Value = objectSchema(
        properties: [
            "subject": [
                "type": "string",
                "description": "Optional subject entity key.",
            ],
            "predicate": [
                "type": "string",
                "description": "Optional predicate key.",
            ],
            "as_of": [
                "type": "integer",
                "description": "Optional query timestamp in ms since epoch for both system and valid time.",
            ],
            "system_as_of": [
                "type": "integer",
                "description": "Optional system-time query timestamp in ms since epoch. Overrides as_of for transaction time.",
            ],
            "valid_as_of": [
                "type": "integer",
                "description": "Optional valid-time query timestamp in ms since epoch. Overrides as_of for fact validity time.",
            ],
            "limit": [
                "type": "integer",
                "description": "Maximum facts to return. Default: 20.",
                "minimum": 1,
                "maximum": 500,
            ],
        ],
        required: []
    )

    static let waxEntityResolve: Value = objectSchema(
        properties: [
            "alias": [
                "type": "string",
                "description": "Alias to resolve.",
            ],
            "limit": [
                "type": "integer",
                "description": "Maximum matches to return. Default: 10.",
                "minimum": 1,
                "maximum": .int(BrokerLimits.maxEntityResolveLimit),
            ],
        ],
        required: ["alias"]
    )

    private static let maxContentBytes = AgentBrokerService.maxContentBytes

    private static func objectSchema(
        properties: [String: Value],
        required: [String],
        includeResponseVerbosity: Bool = true
    ) -> Value {
        var properties = properties
        if includeResponseVerbosity {
            properties["verbosity"] = responseVerbositySchema
        }
        return [
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map(Value.string)),
            "additionalProperties": false,
        ]
    }

    private static let scalarMetadataValueSchema: Value = [
        "oneOf": [
            ["type": "string"],
            ["type": "integer"],
            ["type": "number"],
            ["type": "boolean"],
        ],
    ]

    private static let responseVerbositySchema: Value = [
        "type": "string",
        "description": "Response verbosity. compact (default) returns one JSON text block; verbose returns narrative text plus structured content.",
        "enum": ["compact", "verbose"],
    ]

    private static func emptyObjectSchema() -> Value {
        objectSchema(properties: [:], required: [])
    }
}
#endif

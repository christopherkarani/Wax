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
            description: "Store text in Wax memory with optional metadata.",
            inputSchema: waxRemember
        ),
        Tool(
            name: "recall",
            description: "Recall context for a query using Wax RAG assembly.",
            inputSchema: waxRecall
        ),
        Tool(
            name: "search",
            description: "Run direct Wax search and return ranked raw hits.",
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
            description: "Search broker-managed session history with provenance-rich results.",
            inputSchema: waxCorpusSearch
        ),
        Tool(
            name: "stats",
            description: "Return Wax runtime and storage stats.",
            inputSchema: waxStats
        ),
        Tool(
            name: "session_start",
            description: "Create a broker-managed virtual session and return its session_id.",
            inputSchema: waxSessionStart
        ),
        Tool(
            name: "session_resume",
            description: "Resume a persisted broker-managed session after restart using session_id or agent/run selectors.",
            inputSchema: waxSessionResume
        ),
        Tool(
            name: "session_end",
            description: "End an active broker-managed virtual session. Pass session_id when multiple sessions are active.",
            inputSchema: waxSessionEnd
        ),
        Tool(
            name: "handoff",
            description: "Store a cross-session handoff note for later retrieval.",
            inputSchema: waxHandoff
        ),
        Tool(
            name: "handoff_latest",
            description: "Fetch the latest handoff note, optionally scoped by project.",
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
        ]

        if structuredMemoryEnabled {
            tools.append(contentsOf: [
                Tool(
                    name: "knowledge_capture",
                    description: "Capture durable knowledge from a natural statement and optionally upsert related entity/fact records.",
                    inputSchema: waxKnowledgeCapture
                ),
                Tool(
                    name: "entity_upsert",
                    description: "Upsert a structured-memory entity by key.",
                    inputSchema: waxEntityUpsert
                ),
                Tool(
                    name: "fact_assert",
                    description: "Assert a structured-memory fact.",
                    inputSchema: waxFactAssert
                ),
                Tool(
                    name: "fact_retract",
                    description: "Retract a structured-memory fact by id.",
                    inputSchema: waxFactRetract
                ),
                Tool(
                    name: "facts_query",
                    description: "Query structured-memory facts.",
                    inputSchema: waxFactsQuery
                ),
                Tool(
                    name: "entity_resolve",
                    description: "Resolve entities by alias.",
                    inputSchema: waxEntityResolve
                ),
            ])
        }

        return tools
    }

    static let waxRemember: Value = objectSchema(
        properties: [
            "content": [
                "type": "string",
                "description": "Text content to store in memory.",
            ],
            "session_id": [
                "type": "string",
                "description": "Optional session UUID to scope this write explicitly. metadata.session_id is rejected.",
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
                "description": "Optional session UUID for scoped recall.",
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
    static let waxStats: Value = emptyObjectSchema()
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
                "description": "Rebuild the broker-managed shared corpus before searching. Default: true.",
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
            "agent_id": ["type": "string", "description": "Stable agent identifier for long-running runtimes."],
            "run_id": ["type": "string", "description": "Stable run identifier for the current autonomous run."],
        ],
        required: []
    )
    static let waxSessionResume: Value = objectSchema(
        properties: [
            "session_id": ["type": "string", "description": "Session UUID to reopen."],
            "agent_id": ["type": "string", "description": "Optional agent selector when session_id is omitted."],
            "run_id": ["type": "string", "description": "Optional run selector when session_id is omitted."],
        ],
        required: []
    )
    static let waxSessionEnd: Value = objectSchema(
        properties: [
            "session_id": [
                "type": "string",
                "description": "Optional session UUID to end explicitly. Required when more than one MCP session is active.",
            ],
        ],
        required: []
    )

    static let waxHandoff: Value = objectSchema(
        properties: [
            "content": [
                "type": "string",
                "description": "Handoff text for the next session.",
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
        ],
        required: ["content"]
    )

    static let waxKnowledgeCapture: Value = objectSchema(
        properties: [
            "content": [
                "type": "string",
                "description": "Natural-language durable knowledge to store.",
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
            "include_surrogates": [
                "type": "boolean",
                "description": "Whether surrogate frames can be included. Default: false.",
            ],
        ],
        required: []
    )

    static let waxHandoffLatest: Value = objectSchema(
        properties: [
            "project": [
                "type": "string",
                "description": "Optional project scope for lookup.",
            ],
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
                            "type": ["type": "string"],
                            "value": .object([:]),
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
                "description": "Optional query timestamp in ms since epoch.",
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
                "maximum": 100,
            ],
        ],
        required: ["alias"]
    )

    private static func objectSchema(properties: [String: Value], required: [String]) -> Value {
        [
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

    private static func emptyObjectSchema() -> Value {
        objectSchema(properties: [:], required: [])
    }
}
#endif

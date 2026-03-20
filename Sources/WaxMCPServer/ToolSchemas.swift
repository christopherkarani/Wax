#if MCPServer
import MCP

enum ToolSchemas {
    static var allTools: [Tool] {
        tools(structuredMemoryEnabled: true)
    }

    static func tools(structuredMemoryEnabled: Bool) -> [Tool] {
        var tools: [Tool] = [
        Tool(
            name: "wax_remember",
            description: "Store text in Wax memory with optional metadata.",
            inputSchema: waxRemember
        ),
        Tool(
            name: "wax_recall",
            description: "Recall context for a query using Wax RAG assembly. Reads require wax_flush when pending writes exist.",
            inputSchema: waxRecall
        ),
        Tool(
            name: "wax_search",
            description: "Run direct Wax search and return ranked raw hits. Reads require wax_flush when pending writes exist.",
            inputSchema: waxSearch
        ),
        Tool(
            name: "wax_corpus_search",
            description: "Build or refresh a shared corpus store from many session .wax files, then search it with provenance-rich results.",
            inputSchema: waxCorpusSearch
        ),
        Tool(
            name: "wax_flush",
            description: "Flush pending Wax writes and commit indexes.",
            inputSchema: waxFlush
        ),
        Tool(
            name: "wax_stats",
            description: "Return Wax runtime and storage stats.",
            inputSchema: waxStats
        ),
        Tool(
            name: "wax_session_start",
            description: "Create a process-local session UUID for explicit memory scoping and return its session_id.",
            inputSchema: waxSessionStart
        ),
        Tool(
            name: "wax_session_end",
            description: "Mark a process-local MCP session inactive. Pass session_id when multiple sessions are active.",
            inputSchema: waxSessionEnd
        ),
        Tool(
            name: "wax_handoff",
            description: "Store a cross-session handoff note for later retrieval. Commit by default; set commit=false to batch with wax_flush.",
            inputSchema: waxHandoff
        ),
        Tool(
            name: "wax_handoff_latest",
            description: "Fetch the latest handoff note, optionally scoped by project.",
            inputSchema: waxHandoffLatest
        ),
        ]

        if structuredMemoryEnabled {
            tools.append(contentsOf: [
                Tool(
                    name: "wax_entity_upsert",
                    description: "Upsert a structured-memory entity by key.",
                    inputSchema: waxEntityUpsert
                ),
                Tool(
                    name: "wax_fact_assert",
                    description: "Assert a structured-memory fact.",
                    inputSchema: waxFactAssert
                ),
                Tool(
                    name: "wax_fact_retract",
                    description: "Retract a structured-memory fact by id.",
                    inputSchema: waxFactRetract
                ),
                Tool(
                    name: "wax_facts_query",
                    description: "Query structured-memory facts.",
                    inputSchema: waxFactsQuery
                ),
                Tool(
                    name: "wax_entity_resolve",
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
            "commit": [
                "type": "boolean",
                "description": "Commit immediately. Default: true. Set false to batch with wax_flush before recall/search reads.",
            ],
        ],
        required: ["content"]
    )

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
                "enum": ["text", "hybrid"],
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
                "enum": ["text", "hybrid"],
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

    static let waxFlush: Value = emptyObjectSchema()
    static let waxStats: Value = emptyObjectSchema()
    static let waxCorpusSearch: Value = objectSchema(
        properties: [
            "query": [
                "type": "string",
                "description": "Search query text.",
            ],
            "sessions_dir": [
                "type": "string",
                "description": "Directory containing source session .wax stores. Default: ~/.wax/sessions",
            ],
            "corpus_store_path": [
                "type": "string",
                "description": "Path to the shared corpus store. Default: ~/.wax/corpus.wax",
            ],
            "rebuild": [
                "type": "boolean",
                "description": "Rebuild the shared corpus before searching. Default: true. If false and the corpus is missing, it is still built.",
            ],
            "recursive": [
                "type": "boolean",
                "description": "Recursively scan sessions_dir for .wax files. Default: true.",
            ],
            "mode": [
                "type": "string",
                "description": "Search mode for the shared corpus.",
                "enum": ["text", "hybrid"],
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
    static let waxSessionStart: Value = emptyObjectSchema()
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
            "commit": [
                "type": "boolean",
                "description": "Commit immediately. Default: true. Set false to batch with wax_flush before dependent reads.",
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
            "commit": [
                "type": "boolean",
                "description": "Commit immediately. Default: true. Set false to batch with wax_flush before dependent reads.",
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
            "valid_from": [
                "type": "integer",
                "description": "Optional valid-from timestamp (ms since epoch).",
            ],
            "valid_to": [
                "type": "integer",
                "description": "Optional valid-to timestamp (ms since epoch).",
            ],
            "commit": [
                "type": "boolean",
                "description": "Commit immediately. Default: true. Set false to batch with wax_flush before dependent reads.",
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
            "commit": [
                "type": "boolean",
                "description": "Commit immediately. Default: true. Set false to batch with wax_flush before dependent reads.",
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

#if MCPServer
import MCP

enum ToolSchemas {
    static let sojuMessage = "Photo RAG requires Soju. Install at waxmcp.dev/soju"

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
            description: "Recall context for a query using Wax RAG assembly.",
            inputSchema: waxRecall
        ),
        Tool(
            name: "wax_search",
            description: "Run direct Wax search and return ranked raw hits.",
            inputSchema: waxSearch
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
            description: "Start a new scoped memory session and return a session_id.",
            inputSchema: waxSessionStart
        ),
        Tool(
            name: "wax_session_end",
            description: "End the active scoped memory session.",
            inputSchema: waxSessionEnd
        ),
        Tool(
            name: "wax_handoff",
            description: "Store a cross-session handoff note for later retrieval.",
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

        tools.append(contentsOf: [
        Tool(
            name: "wax_video_ingest",
            description: "Ingest one or more local video files into Video RAG.",
            inputSchema: waxVideoIngest
        ),
        Tool(
            name: "wax_video_recall",
            description: "Recall timecoded segments from Video RAG.",
            inputSchema: waxVideoRecall
        ),
        Tool(
            name: "wax_photo_ingest",
            description: "Photo RAG ingest — not available in this build. Requires Soju: waxmcp.dev/soju",
            inputSchema: waxPhotoIngest
        ),
        Tool(
            name: "wax_photo_recall",
            description: "Photo RAG recall — not available in this build. Requires Soju: waxmcp.dev/soju",
            inputSchema: waxPhotoRecall
        ),
        ])
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
                "description": "Optional session UUID to scope this write explicitly.",
            ],
            "metadata": [
                "type": "object",
                "description": "Optional metadata map. Scalar values are coerced to strings.",
                "additionalProperties": true,
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
        ],
        required: ["query"]
    )

    static let waxFlush: Value = emptyObjectSchema()
    static let waxStats: Value = emptyObjectSchema()
    static let waxSessionStart: Value = emptyObjectSchema()
    static let waxSessionEnd: Value = emptyObjectSchema()

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
                "description": "Commit immediately. Default: true. Set false to batch with wax_flush.",
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
                "description": "Commit immediately. Default: true. Set false to batch with wax_flush.",
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
                "description": "Commit immediately. Default: true. Set false to batch with wax_flush.",
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

    static let waxVideoIngest: Value = objectSchema(
        properties: [
            "paths": [
                "type": "array",
                "description": "Local file paths to ingest.",
                "items": ["type": "string"],
                "minItems": 1,
                "maxItems": 50,
            ],
            "id": [
                "type": "string",
                "description": "Optional stable ID for single-path ingest.",
            ],
        ],
        required: ["paths"]
    )

    static let waxVideoRecall: Value = objectSchema(
        properties: [
            "query": [
                "type": "string",
                "description": "Video recall query text.",
            ],
            "time_range": [
                "type": "object",
                "description": "Optional unix timestamp range in seconds.",
                "properties": [
                    "start": ["type": "number"],
                    "end": ["type": "number"],
                ],
                "required": ["start", "end"],
                "additionalProperties": false,
            ],
            "limit": [
                "type": "integer",
                "description": "Max videos to return. Default: 5.",
                "minimum": 1,
                "maximum": 100,
            ],
        ],
        required: ["query"]
    )

    // TODO: Replace with proper schemas when Soju photo RAG integration is complete.
    // These tools are advertised but return isError:true — the stub schema uses
    // additionalProperties:true so MCP clients that pass arguments (e.g. path, query)
    // reach the tool handler and get the informative "Requires Soju" error response,
    // rather than being rejected by schema validation before the tool even runs.
    static let waxPhotoIngest: Value = stubObjectSchema()
    static let waxPhotoRecall: Value = stubObjectSchema()

    private static func objectSchema(properties: [String: Value], required: [String]) -> Value {
        [
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map(Value.string)),
            "additionalProperties": false,
        ]
    }

    private static func emptyObjectSchema() -> Value {
        objectSchema(properties: [:], required: [])
    }

    /// A permissive placeholder schema for stub tools that returns `isError:true`.
    /// Uses `additionalProperties:true` so any client-provided arguments pass
    /// schema validation and the call reaches the handler (which returns the
    /// informative "Requires Soju" error), rather than being rejected by the
    /// client's schema validator before the tool runs.
    private static func stubObjectSchema() -> Value {
        [
            "type": "object",
            "properties": .object([:]),
            "required": .array([]),
            "additionalProperties": true,
        ]
    }
}
#endif

#if MCPServer
import MCP

enum ToolSchemas {
    static let sojuMessage = "Photo RAG requires Soju. Install at waxmcp.dev/soju"

    static let allTools: [Tool] = [
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
    ]

    static let waxRemember: Value = objectSchema(
        properties: [
            "content": [
                "type": "string",
                "description": "Text content to store in memory.",
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
        ],
        required: ["query"]
    )

    static let waxFlush: Value = emptyObjectSchema()
    static let waxStats: Value = emptyObjectSchema()

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

    static let waxPhotoIngest: Value = emptyObjectSchema()
    static let waxPhotoRecall: Value = emptyObjectSchema()

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
}
#endif

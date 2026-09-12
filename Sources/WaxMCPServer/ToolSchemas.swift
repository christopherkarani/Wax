#if MCPServer
import MCP
import Wax

/// Host tool listing derived from `BrokerCommandCatalog`.
///
/// This module owns no command knowledge: names, summaries, arguments, and
/// profile views come from the catalog, and schemas are rendered from catalog
/// entries through the value bridge. The `wax*` accessors below exist for the
/// schema contract tests; production paths go through `tools`.
enum ToolSchemas {
    /// Full public catalog, independent of `WAX_MCP_TOOLS`.
    static var allTools: [Tool] {
        allPublishedTools
    }

    static var allPublishedTools: [Tool] {
        tools(structuredMemoryEnabled: true, profile: .full)
    }

    static func tools(
        structuredMemoryEnabled: Bool,
        profile: MCPToolProfile = .fromEnvironment()
    ) -> [Tool] {
        BrokerCommandCatalog.toolRows(
            profile: profile.catalogProfile,
            structuredMemoryEnabled: structuredMemoryEnabled
        ).map { row in
            Tool(
                name: row.name,
                description: row.summary,
                inputSchema: mcpValue(from: BrokerCommandCatalog.schema(for: row.entry))
            )
        }
    }

    private static func schemaValue(_ command: String) -> Value {
        guard let entry = BrokerCommandCatalog.entry(for: command) else {
            preconditionFailure("Catalog is missing command '\(command)'")
        }
        return mcpValue(from: BrokerCommandCatalog.schema(for: entry))
    }

    static var waxRemember: Value { schemaValue("remember") }
    static var waxMemoryAppend: Value { schemaValue("memory_append") }
    static var waxMemorySearch: Value { schemaValue("memory_search") }
    static var waxMemoryGet: Value { schemaValue("memory_get") }
    static var waxRecall: Value { schemaValue("recall") }
    static var waxSearch: Value { schemaValue("search") }
    static var waxSessionSynthesize: Value { schemaValue("session_synthesize") }
    static var waxMemoryPromote: Value { schemaValue("memory_promote") }
    static var waxPromote: Value { schemaValue("promote") }
    static var waxMemoryHealth: Value { schemaValue("memory_health") }
    static var waxCorpusSearch: Value { schemaValue("corpus_search") }
    static var waxStats: Value { schemaValue("stats") }
    static var waxSessionStart: Value { schemaValue("session_start") }
    static var waxSessionResume: Value { schemaValue("session_resume") }
    static var waxSessionEnd: Value { schemaValue("session_end") }
    static var waxSessionClose: Value { schemaValue("session_close") }
    static var waxSessionOpen: Value { schemaValue("session_open") }
    static var waxHandoff: Value { schemaValue("handoff") }
    static var waxHandoffLatest: Value { schemaValue("handoff_latest") }
    static var waxCompactContext: Value { schemaValue("compact_context") }
    static var waxMarkdownExport: Value { schemaValue("markdown_export") }
    static var waxMarkdownSync: Value { schemaValue("markdown_sync") }
    static var waxTaskStateMigrate: Value { schemaValue("task_state_migrate") }
    static var waxKnowledgeCapture: Value { schemaValue("knowledge_capture") }
    static var waxEntityUpsert: Value { schemaValue("entity_upsert") }
    static var waxFactAssert: Value { schemaValue("fact_assert") }
    static var waxFactRetract: Value { schemaValue("fact_retract") }
    static var waxFactsQuery: Value { schemaValue("facts_query") }
    static var waxEntityResolve: Value { schemaValue("entity_resolve") }

    static var searchFilters: Value {
        mcpValue(from: BrokerCommandCatalog.schemaFragment(for: .init("filters", .filters)))
    }
}
#endif

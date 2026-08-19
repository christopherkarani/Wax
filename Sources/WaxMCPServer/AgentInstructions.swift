#if MCPServer
import Foundation

/// Host-facing MCP server instructions. Every agent that connects should receive
/// this lifecycle playbook without needing a separate skill install.
enum MCPAgentInstructions {
    static func text(version: String) -> String {
        """
        Wax MCP durable agent memory (server v\(version)).

        Session lifecycle (required):
        1) Call handoff_latest first (optional project) to resume prior context.
        2) Call session_start once and keep the returned session_id for the session. The same agent_id+run_id resumes the active session.
        3) Before answering from memory, call recall (default) or search (raw ranked hits). recall with session_id merges that session with durable long-term memory.
        4) When you learn durable facts, call remember with concise factual content. Pass session_id as a top-level argument for session-scoped writes — never put session_id inside metadata.
        5) Near session end, call handoff (content, optional project/pending_tasks/session_id), then session_end. session_end `active` is THIS session (false after end). `remaining_active` / `active_session_count` are other live sessions in the broker.

        Tool selection:
        - recall: assembled RAG context (preferred read path)
        - search: raw ranked hits; prefer mode hybrid unless a lexical text search is requested
        - corpus_search: cross-session history with provenance
        - entity_*/fact_*: stable structured knowledge, not transient debug notes
        - stats: health / embedder / store check

        Do not manage SESSION_STORE, --store-path, or flush in normal agent flows. The broker owns long-term memory and virtual session stores.

        Behavior: read handoffs and recall results before asking the user to restate prior context; keep memory writes concise and task-scoped; cite provenance on cross-session hits.
        """
    }
}
#endif

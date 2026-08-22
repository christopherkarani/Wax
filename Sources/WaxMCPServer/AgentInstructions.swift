#if MCPServer
import Foundation

/// Host-facing MCP server instructions. Every agent that connects should receive
/// this lifecycle playbook without needing a separate skill install.
enum MCPAgentInstructions {
    static func text(version: String) -> String {
        """
        Wax MCP durable agent memory (server v\(version)).

        Session lifecycle (required):
        1) Prefer session_open(project?, agent_id?, run_id?, recall_query?) for a one-shot open, or call handoff_latest first (optional project) then session_start once and keep the returned session_id. The same agent_id+run_id resumes the active session.
        2) Before answering from memory, call recall (default) or search (raw ranked hits). Default recall scope is project: hard-filters to resolved project (explicit project, session project, or cwd/git root). Empty project lane returns an explicit miss — never auto-widens to global. Pass scope=global only when cross-project retrieval is intentional. Passing session_id merges that session with durable long-term memory under project scope.
        3) When you learn durable facts, call remember with concise factual content. Prefer scope=session|durable; session requires top-level session_id; durable forbids session_id. Never put session_id inside metadata.
        4) Near session end, prefer session_close(session_id, content, optional project/pending_tasks) for atomic handoff+end. Keep content to a concise state summary; put unfinished work only in pending_tasks and never store transcripts. Or call handoff then session_end. session_end/session_close `active` is THIS session (false after end). `remaining_active` / `active_session_count` are other live sessions in the broker.
        5) A persisted session_id survives broker hops: remember/recall/handoff rebind that UUID when the manifest is still active. Ended/unknown UUIDs return structured inactive errors (resumable=false).

        Canonical verbs: session_open, remember, recall, session_close, stats.

        Tool selection:
        - recall: assembled RAG context (preferred read path); default scope=project
        - search: raw ranked hits; prefer mode hybrid unless a lexical text search is requested
        - corpus_search: cross-session history with provenance
        - entity_*/fact_*: stable structured knowledge, not transient debug notes
        - stats: health / embedder / store check

        Do not manage SESSION_STORE, --store-path, or flush in normal agent flows. The broker owns long-term memory and virtual session stores.

        Responses default to one compact JSON content block. Pass verbosity=verbose only when narrative text plus structuredContent is useful.

        Behavior: read handoffs and recall results before asking the user to restate prior context; keep memory writes concise and task-scoped; cite provenance on cross-session hits.
        """
    }
}
#endif

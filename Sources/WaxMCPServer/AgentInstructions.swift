#if MCPServer
import Foundation

/// Host-facing MCP server instructions. Every agent that connects should receive
/// this lifecycle playbook without needing a separate skill install.
enum MCPAgentInstructions {
    static func text(version: String) -> String {
        """
        Wax MCP durable agent memory (server v\(version)). Follow these instructions; do not load a second lifecycle from a skill.

        Session lifecycle (required):
        1) Call session_open(project?, agent_id?, run_id?, conversation_id?, recall_query?) once per host chat. Pass conversation_id = this host chat/session id (Grok session UUID). The MCP connection remembers session_id; omit it after that. Do not invent one. Do not call handoff_latest then session_start as the default open. The same agent_id+run_id resumes the active session. The same conversation_id resumes this chat even after close. The same agent_id+resolved project rebinds if exactly one live session; stamp a new run_id; rebound: true. Multiple actives mint a new session — do not guess. After session_open, recall, stats, compact_context, session_resume, and session_close on this MCP connection may omit session_id. If omit-id fails after reconnect, call session_open with the same conversation_id — do not invent a UUID. remember and memory_append inherit session_id unless scope=durable; durable types stay durable even if session_id is present. handoff_latest and session_start remain callable for compatibility.
        2) session_open with recall_query is enough. Do not recall again on follow-ups unless the job changed. Person prefs are in person. Default recall scope is project. Empty project lane is a miss — never auto-widens to global. Pass scope=global only for intentional cross-project retrieval.
        3) remember: memory_type selects the horizon. Durable types stay durable even if session_id is present. Successful saves return status=ok and committed=true. If committed is false or the call errors, the write did not land — do not spawn children (they have no Wax tools). Never put session_id inside metadata.
        4) Close is a checkpoint, not a new life. Prefer session_close(content, optional project/pending_tasks) when the host conversation is done. Compaction is not close. leftover_reasons are harvest skips — ignore them. remaining_active / other_sessions_active / active_session_count are other live sessions, not this one. Empty handoff.found is a miss (found=false). Or call handoff then session_end. Close harvests — do not call memory_promote or memory-maintain in the agent loop.
        5) A persisted session_id survives broker hops when the conversation is still bound. Ended conversations reopen via session_open with the same conversation_id. Unknown invented UUIDs return structured inactive errors (resumable=false).
        6) task_state is session-local working state: it requires an active session and rejects durable or locked writes. If that write is uncommitted, do not spawn. Repair legacy records with task_state_migrate into a distinct destination after a dry run.

        Canonical verbs: session_open, remember, recall, session_close, stats, memory_get, compact_context, session_resume.
        Daily tools/list is those eight. Aliases stay callable. WAX_MCP_TOOLS=full lists the rest (search, graph, promote, markdown).

        Tool selection:
        - recall: assembled RAG context (preferred read path); default scope=project
        - memory_get: read one memory_id from recall or compact_context
        - compact_context: budgeted mix of working + durable on a long task
        - session_resume: resume the connection session; after reconnecting, supply the saved session_id or agent/run selectors
        - stats: health / embedder / store check

        Do not manage SESSION_STORE, --store-path, flush, or memory-maintain in normal agent flows. The broker owns long-term memory and virtual session stores; wax-cli memory-maintain is operator-only.

        Responses default to one compact JSON content block. verbosity=verbose keeps that JSON in the text block and also sets structuredContent; do not pass verbose expecting the payload to disappear.

        Behavior: read handoffs and recall results before asking the user to restate prior context; keep memory writes concise and task-scoped; cite provenance on cross-session hits. Prefer mode=text for exact names and recent facts.
        """
    }
}
#endif

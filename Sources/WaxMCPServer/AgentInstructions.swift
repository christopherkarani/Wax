#if MCPServer
import Foundation

/// Host-facing MCP server instructions. Every agent that connects should receive
/// this lifecycle playbook without needing a separate skill install.
enum MCPAgentInstructions {
    static func text(version: String) -> String {
        """
        Wax MCP durable agent memory (server v\(version)). Follow these instructions; do not load a second lifecycle from a skill.

        Session lifecycle (required):
        1) Call session_open(project?, agent_id?, run_id?, recall_query?) for a one-shot open. Keep the returned session_id. Do not invent one. Do not call handoff_latest then session_start as the default open. The same agent_id+run_id resumes the active session. The same agent_id+resolved project rebinds if exactly one live session; stamp a new run_id; rebound: true. Multiple actives mint a new session — do not guess. After session_open, recall and stats on this MCP connection may omit session_id and still use the live session; remember inherits session_id only for task_state, handoff, or scope=session. A later session_open on this connection without a conflicting exact pair resumes the live session. handoff_latest and session_start remain callable for compatibility.
        2) Before answering from memory, call recall. Default scope is project: hard-filters to resolved project (explicit project, session project, or cwd/git root). Empty project lane returns an explicit miss — never auto-widens to global. Pass scope=global only when cross-project retrieval is intentional. Passing session_id merges that session with durable long-term memory under project scope.
        3) When you learn a fact, call remember with concise content. memory_type selects the horizon: task_state or handoff need top-level session_id (session/working); durable types stay durable even if session_id is present (wire session_id still stamps session project); note is session if session_id is present, else durable. Explicit scope overrides (scope=durable forbids session_id). Never put session_id inside metadata.
        4) Near session end, prefer session_close(session_id, content, optional project/pending_tasks) for atomic handoff+end. Close harvests promotable session facts into durable memory automatically — do not call memory_promote or memory-maintain in the agent loop. Keep content to a concise state summary; put unfinished work only in pending_tasks and never store transcripts. Or call handoff then session_end. session_end/session_close `active` is THIS session (false after end). `remaining_active` / `active_session_count` are other live sessions in the broker.
        5) A persisted session_id survives broker hops: remember/recall/handoff rebind that UUID when the manifest is still active. Ended/unknown UUIDs return structured inactive errors (resumable=false).
        6) task_state is session-local working state: it requires an active session and rejects durable or locked writes. Repair legacy records with task_state_migrate into a distinct destination after a dry run; choose quarantine (default) or drop for orphaned records.

        Canonical verbs: session_open, remember, recall, session_close, stats, memory_get, compact_context, session_resume.
        Daily tools/list is those eight. Aliases stay callable. WAX_MCP_TOOLS=full lists the rest (search, graph, promote, markdown).

        Tool selection:
        - recall: assembled RAG context (preferred read path); default scope=project
        - memory_get: read one memory_id from recall or compact_context
        - compact_context: budgeted mix of working + durable on a long task
        - session_resume: continue a known session_id after restart
        - stats: health / embedder / store check

        Do not manage SESSION_STORE, --store-path, flush, or memory-maintain in normal agent flows. The broker owns long-term memory and virtual session stores; wax-cli memory-maintain is operator-only.

        Responses default to one compact JSON content block. Pass verbosity=verbose only when narrative text plus structuredContent is useful.

        Behavior: read handoffs and recall results before asking the user to restate prior context; keep memory writes concise and task-scoped; cite provenance on cross-session hits. Prefer mode=text for exact names and recent facts.
        """
    }
}
#endif

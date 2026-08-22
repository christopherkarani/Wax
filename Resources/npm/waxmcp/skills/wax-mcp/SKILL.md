---
name: wax-mcp
description: >
  Operator playbook for the Wax MCP memory server. Use whenever Wax MCP tools are
  available (remember, recall, search, handoff, session_start/end, structured
  memory), when installing or configuring waxmcp, or when an agent should keep
  durable cross-session memory. Prefer this skill over the Swift framework skill
  unless the task is writing Wax Swift code.
---

# Wax MCP (Agent Memory Operator)

## Purpose

Teach agents how to **use** the Wax MCP server correctly every session.

This is not the Swift framework skill. For embedding Wax in Swift apps, use the
`wax` skill under `Resources/skills/public/wax`.

## Session Lifecycle (required)

1. **Start**
   - Call `handoff_latest` first (optionally with `project`) to load prior context.
   - Call `session_start` once. Pass stable `agent_id` and `run_id` so a retry reuses the same session.
   - Keep the returned `session_id` for the rest of the session.
2. **Work**
   - Before answering from memory, call `recall` (default) or `search` (raw hits). `recall` with `session_id` merges that session with durable long-term memory.
   - When you learn something durable, call `remember` with concise factual text.
   - For session-scoped writes, pass `session_id` as a **top-level** argument.
   - Never put `session_id` inside `metadata`.
3. **End**
   - Call `handoff` with `content`, optional `project`, optional `pending_tasks`, optional `session_id`.
   - Keep `content` to a concise state summary. Put unfinished work only in `pending_tasks`; do not copy pending tasks into content or store transcripts.
   - Call `session_end` (pass `session_id` when multiple sessions may be active).
   - `session_end` `active` is THIS session (false after end). `remaining_active` / `active_session_count` are other live sessions in the broker.

## Read Path

| Goal | Tool |
|------|------|
| Assembled RAG context for the current question | `recall` |
| Raw ranked hits / debugging retrieval | `search` |
| Cross-session history with provenance | `corpus_search` |
| Health / embedder / store stats | `stats` |

Search mode guidance:

- Prefer `mode: "hybrid"` when semantic recall helps.
- Use `mode: "text"` for fast or deterministic lexical lookup.

Response guidance:

- Responses default to one compact JSON content block.
- Pass `verbosity: "verbose"` only when narrative text plus standard MCP `structuredContent` is useful.

## Write Path

| Kind of knowledge | Tool |
|-------------------|------|
| Decisions, preferences, discoveries, short facts | `remember` |
| Stable entities in a knowledge graph | `entity_upsert` / `entity_resolve` |
| Structured facts that can be retracted later | `fact_assert` / `fact_retract` / `facts_query` |
| Natural-language knowledge capture (when available) | `knowledge_capture` |

Write quality rules:

- Keep content concise, factual, and task-scoped.
- Prefer corrections: store the corrected fact; retract stale structured facts with `fact_retract`.
- Do not store secrets, credentials, or large blobs unless the user explicitly asks.

## Anti-Patterns (do not do these)

- Do not manage `SESSION_STORE`, `--store-path`, or `flush` in normal agent flows.
  The broker owns long-term memory and virtual session stores.
- Do not skip `handoff_latest` at session start and re-ask the user for prior context.
- Do not invent a `session_id`; only use values returned by `session_start` / `session_resume`.
- Do not put `session_id` inside `metadata`.
- Do not treat `search` as the default when `recall` is enough.
- Do not use structured fact tools for transient debug notes.

## Behavior Expectations

- Read handoffs and recall results before asking the user to restate known context.
- When a cross-session hit matters, cite provenance so the user knows which session store it came from.
- Use `session_resume` only when continuing a known persisted `session_id` after a restart.
- Use `compact_context` / `session_synthesize` / promotion tools only when the task needs long-horizon compaction or durable promotion, not as default chatter.
- Prefer `mode: "text"` for recent facts, exact names, and identity. Hybrid can rank old test frames first.
- `memory_get` IDs are `durable:<frame>` or `episodic:<session_id>:<frame>`. Never a bare frame number.

## Install / Host Setup (for humans and setup agents)

Stage binaries once:

```bash
npx -y waxmcp@latest install
```

Then wire the **host**, not a new prompt:

| Host | What to do |
|------|------------|
| Claude Code | `swift run --traits MCPServer wax-cli mcp install --scope user` then `claude install-skill ~/.local/share/waxmcp/skills/wax-mcp` |
| Codex | HTTP URL in `~/.codex/config.toml` + copy this skill to `~/.codex/skills/wax-mcp` |
| Cursor | HTTP URL in `~/.cursor/mcp.json` + paste `references/project-rules.md` |
| Hermes | HTTP + `memory.provider: wax-memory` + copy this skill + append the SOUL.md stanza to `~/.hermes/SOUL.md` |
| OpenClaw | HTTP + memory plugin + append the SOUL.md stanza to workspace `SOUL.md` |
| Other | HTTP URL + paste the AGENTS.md fence from `references/project-rules.md` |

Two or more clients must share **one** HTTP server on `http://127.0.0.1:3000/mcp`. Snippets and smoke test: `Resources/docs/wax-mcp-hosts.md`.

The npm launcher serves MCP. It does **not** implement `mcp install --scope`.

```bash
# Claude skill (if wax-cli install did not auto-register)
claude install-skill ~/.local/share/waxmcp/skills/wax-mcp
# or from source
claude install-skill https://github.com/christopherkarani/Wax/tree/main/Resources/skills/public/wax-mcp
```

Project rules fallback: paste the AGENTS.md fence from
`references/project-rules.md` into `CLAUDE.md` or `AGENTS.md` when the host
does not load skills. Hermes / OpenClaw: append the SOUL.md fence instead of
replacing the soul.

## Quick Tool Map

| Tool | When |
|------|------|
| `handoff_latest` | Session start continuity |
| `session_start` / `session_end` | Broker session lifecycle |
| `session_resume` | Resume a known session after restart |
| `remember` | Store durable free-text memory |
| `recall` | Default read / RAG assembly |
| `search` | Raw ranked hits |
| `handoff` | End-of-session summary + pending tasks |
| `corpus_search` | Cross-session search with provenance |
| `stats` | Health check |
| `entity_*` / `fact_*` | Structured knowledge graph |

## References

- `references/project-rules.md` — pasteable project instruction block
- Repo setup doc: `Resources/docs/wax-mcp-setup.md`

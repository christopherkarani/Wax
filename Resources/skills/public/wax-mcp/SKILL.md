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

## Source of truth

The host-facing lifecycle playbook is defined in
`Sources/WaxMCPServer/AgentInstructions.swift` (`MCPAgentInstructions`) and shipped
as MCP server `instructions` on every tools connection. **Edit that file when the
playbook changes.** This skill and `references/project-rules.md` must stay aligned
with it — do not invent a conflicting second essay.

Root repo `AGENTS.md` is contributor hygiene only; do not overwrite it with this
memory playbook.

## Session Lifecycle (required)

Matches `AgentInstructions.swift`:

1. Call `handoff_latest` first (optional `project`) to resume prior context.
2. Call `session_start` once and keep the returned `session_id`.
3. Before answering from memory, call `recall` (default) or `search` (raw ranked hits).
4. When you learn durable facts, call `remember` with concise factual content. Pass
   `session_id` as a **top-level** argument for session-scoped writes — never put
   `session_id` inside `metadata`.
5. Near session end, call `handoff` (`content`, optional `project` / `pending_tasks` /
   `session_id`), then `session_end`.

## Intended primary search path

| Goal | Tool / mode |
|------|-------------|
| Assembled RAG context (preferred read) | `recall` |
| Raw ranked hits | `search` with `mode: "hybrid"` unless lexical-only is requested |
| Cross-session history with provenance | `corpus_search` |
| Health / embedder / store | `stats` |

> Code note: some `search` call paths still default omitted `mode` to `"text"`.
> Prefer hybrid in agent calls; aligning wire defaults is Phase 4 (#94).

There are **no** `photo_*` or `video_*` MCP tools. Store transcript / photo-derived
text with `remember` until multimodal MCP tools exist. Tool list:
`Sources/WaxMCPServer/ToolSchemas.swift`.

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

## Install / Host Setup (for humans and setup agents)

```bash
npx -y waxmcp@latest mcp install --scope user
```

That command stages the runtime, registers the MCP server, and stages this skill
under `~/.local/share/waxmcp/skills/wax-mcp` (or `$WAX_MCP_INSTALL_ROOT/../skills`
when the install root is overridden).

```bash
claude install-skill ~/.local/share/waxmcp/skills/wax-mcp
# or from source
claude install-skill https://github.com/christopherkarani/Wax/tree/main/Resources/skills/public/wax-mcp
```

Project rules fallback: paste `references/project-rules.md` into `CLAUDE.md` or an
**app** `AGENTS.md` when the host does not load skills automatically. Full setup:
`Resources/docs/wax-mcp-setup.md`.

## Quick Tool Map

| Tool | When |
|------|------|
| `handoff_latest` | Session start continuity |
| `session_start` / `session_end` | Broker session lifecycle |
| `session_resume` | Resume a known session after restart |
| `remember` | Store durable free-text memory |
| `recall` | Default read / RAG assembly |
| `search` | Raw ranked hits (prefer hybrid) |
| `handoff` | End-of-session summary + pending tasks |
| `corpus_search` | Cross-session search with provenance |
| `stats` | Health check |
| `entity_*` / `fact_*` | Structured knowledge graph |

## References

- SoT: `Sources/WaxMCPServer/AgentInstructions.swift`
- `references/project-rules.md` — pasteable project instruction block (must match SoT)
- Repo setup doc: `Resources/docs/wax-mcp-setup.md`

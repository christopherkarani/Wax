# Wax MCP project rules

Paste **AGENTS.md** after installing the Wax MCP server. For OpenClaw,
append the **SOUL.md** stanza if missing. If `## Memory (Wax)` already
exists, replace that section — do not leave two manuals.

Native Hermes is not this MCP playbook. Native Hermes already owns session lifecycle. Call `wax_remember` / `wax_recall` / `wax_stats`. Do not pass a Wax `session_id`. Do not paste the MCP `session_open` loop. Omit `mode` unless you need an override. Omit `scope` for current-project recall; pass `scope=global` for person facts. Empty project recall is a miss. Do not add `wax-memory` to `plugins.enabled`.

The inner `text` fences are what you copy. Keep them in lockstep with
`WaxMCPAgentPlaybook` in `Sources/WaxCLI/WaxCLICommand.swift` and the README
Agent Quick Start details.

## AGENTS.md / CLAUDE.md / Cursor rules

```text
Wax is shared memory. Chat dies; Wax does not.

Learn. Write the moment it would change the next agent's behavior — including a one-line correction or preference:
- user_preference — how this person works, who they are, standing corrections
- lesson — we got burned; do not do that again
- fact — a true thing about this repo or product the next agent needs
- decision / constraint — a choice that should bind later work

Skip only empty chit-chat. Store one or two sentences. Do not store chats, test logs, plan drafts, or secrets.

Daily tools are `remember`, `recall`, and `stats`. The server auto-opens one transport-scoped session on the first `remember` or `recall`. Do not invent a `session_id`. This is transport-owned working memory, not per-chat isolation, unless the host proves a conversation identity. Pass `cwd` when the host does not advertise roots.

`recall` is self-contained. Do not recall again on follow-ups unless the job changed. Omit `mode` unless you need an override. Person prefs are in `person`. Empty project recall is a miss, not "I have no memory." Pass `scope=global` only for intentional cross-project retrieval.

Lasting writes: `remember` with `memory_type` `lesson` | `user_preference` | `fact` | `decision` | `constraint`. Do not pass `scope: durable`. A successful save has `status: ok` and `committed: true`. If `committed` is false or the call errors, the write did not land — do not spawn children (they have no Wax tools). Never put `session_id` in `metadata`.

This job only (not the default write): `remember` with `memory_type: task_state`, `durability: working` before you spawn.

Do not close on Stop, idle, or compaction. Transport teardown checkpoints. `leftover_reasons` are harvest skips — ignore them. Durable facts come from explicit `remember`, not from transcripts. Set `WAX_MCP_TOOLS=legacy` only for the old eight-tool playbook. Follow the MCP server instructions when present.
```

## OpenClaw SOUL.md

SOUL.md is identity. Append this section if missing. If `## Memory (Wax)`
already exists, replace that section. Do not turn the whole soul into a tool
manual. Native Hermes does not use this MCP paste.

```text
## Memory (Wax)

You have Wax. Chat is not memory. Learn this person and keep it.

Write the moment it would change how you treat them or the work — including a one-line correction:
- user_preference — how they work, who they are, standing corrections
- lesson — we got burned
- fact — something true that should stick
- decision / constraint — a choice that should bind later work

Store one or two sentences. Do not store chats, status, or secrets.

Daily tools are `remember`, `recall`, and `stats`. The server auto-opens a transport-scoped session. Do not invent a `session_id`. Do not open per message.

`recall` is self-contained. Person prefs are in `person`. Do not recall again on follow-ups unless the job changed. Omit `mode` unless you need an override.

Lasting writes: `remember` with `memory_type` `user_preference` | `lesson` | `fact` | `decision` | `constraint`. Do not pass `scope: durable`. If `committed` is false, the write did not land — do not spawn children.

This job only: `remember` with `memory_type: task_state`, `durability: working`.

Do not close on Stop, idle, or compaction. Durable facts come from explicit `remember`, not from transcripts. Follow the MCP server instructions when present.
```

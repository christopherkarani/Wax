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
Follow the live Wax MCP server instructions for `remember`, `recall`, and `stats`. Do not invent a `session_id`. Do not load the `wax` or `wax-mcp` skills at session start. `wax` is Swift SDK only; `wax-mcp` is install/doctor only.
```

## OpenClaw SOUL.md

SOUL.md is identity. Append this section if missing. If `## Memory (Wax)`
already exists, replace that section. Do not turn the whole soul into a tool
manual. Native Hermes does not use this MCP paste.

```text
## Memory (Wax)

You have Wax. Follow the live MCP server instructions for `remember`, `recall`, and `stats`. Do not invent a `session_id`. Do not load wax-mcp at session start.
```

---
name: wax-mcp
description: >
  Operator playbook pointer for the Wax MCP memory server. Follow the live
  server instructions. Use when Wax MCP tools are available, or when
  installing or configuring waxmcp. Prefer this skill over the Swift
  framework skill unless the task is writing Wax Swift code.
---

# Wax MCP

The MCP server `instructions` field is the playbook. Do not restate a second
lifecycle here.

Daily tools: `session_open`, `remember`, `recall`, `session_close`, `stats`,
`memory_get`, `compact_context`, `session_resume`. Aliases stay callable.
`WAX_MCP_TOOLS=full` lists the rest.

Close harvests. Do not call `memory_promote` or `memory-maintain` in the agent
loop. Never invent a `session_id` or put it in `metadata`.

Recall defaults to the current project after project/repo resolution. Empty
project recall is a miss, not “I have no memory.” Supplying both `project`
and `repo` requires both exact tags. Pass `scope=global` only for
cross-project retrieval (person facts, standing preferences). Global
searches the entire local store with no current-project rank boost. It is
not an authorization boundary.

Pasteable host rules: `references/project-rules.md`.

This is not the Swift framework skill. For embedding Wax in Swift apps, use
`Resources/skills/public/wax`.

## Install / Host Setup

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
| Hermes | Native `memory.provider: wax-memory` only (`npx -y waxmcp@latest install-hermes-plugin`). Never `plugins.enabled`. Never also `mcp_servers.wax`; do not also register generic MCP or this generic skill. Call `wax_remember` / `wax_recall` / `wax_stats` with no Wax UUID. |
| OpenClaw | HTTP + memory plugin + paste the SOUL.md stanza into workspace `SOUL.md` (replace existing `## Memory (Wax)`) |
| Other | HTTP URL + paste the AGENTS.md fence from `references/project-rules.md` |

Optional: `wax-cli mcp install --write-host-rule PATH` writes the generated
host-rule blob. It never overwrites a host rule unless that flag is set.

Two or more clients must share **one** HTTP server on
`http://127.0.0.1:3000/mcp`. Snippets and smoke test:
`Resources/docs/wax-mcp-hosts.md`.

The npm launcher serves MCP. It does **not** implement `mcp install --scope`.

## Diagnose / recover

```bash
npx -y waxmcp@latest doctor
npx -y waxmcp@latest vector-health
```

`vector-health` is green only when both `vectorSearchEnabled` and
`queryEmbeddingAvailable` are true. After `install`, restart HTTP if it is
already a service — do not start a second writer:

```bash
launchctl kickstart -k "gui/$(id -u)/ai.wax.mcp-http"
# or: ~/.local/share/waxmcp/bin/start-wax-mcp-http.sh
```

Native Hermes, after `install-hermes-plugin` from this tree:

```bash
hermes wax-memory doctor
hermes plugins doctor wax-memory
```

`hermes wax-memory` registers `status`, `doctor`, and `config` only. If
those doctors fail to register or import, reinstall the plugin. Do not add
`wax-memory` to `plugins.enabled`.

```bash
# Claude skill (if wax-cli install did not auto-register)
claude install-skill ~/.local/share/waxmcp/skills/wax-mcp
# or from source
claude install-skill https://github.com/christopherkarani/Wax/tree/main/Resources/skills/public/wax-mcp
```

## References

- `references/project-rules.md` — pasteable project instruction block
- Repo setup doc: `Resources/docs/wax-mcp-setup.md`

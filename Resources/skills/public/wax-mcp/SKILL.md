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
| Hermes | HTTP + `memory.provider: wax-memory` + copy this skill + append the SOUL.md stanza to `~/.hermes/SOUL.md` |
| OpenClaw | HTTP + memory plugin + append the SOUL.md stanza to workspace `SOUL.md` |
| Other | HTTP URL + paste the AGENTS.md fence from `references/project-rules.md` |

Optional: `wax-cli mcp install --write-host-rule PATH` writes the generated
host-rule blob. It never overwrites a host rule unless that flag is set.

Two or more clients must share **one** HTTP server on
`http://127.0.0.1:3000/mcp`. Snippets and smoke test:
`Resources/docs/wax-mcp-hosts.md`.

The npm launcher serves MCP. It does **not** implement `mcp install --scope`.

```bash
# Claude skill (if wax-cli install did not auto-register)
claude install-skill ~/.local/share/waxmcp/skills/wax-mcp
# or from source
claude install-skill https://github.com/christopherkarani/Wax/tree/main/Resources/skills/public/wax-mcp
```

## References

- `references/project-rules.md` — pasteable project instruction block
- Repo setup doc: `Resources/docs/wax-mcp-setup.md`

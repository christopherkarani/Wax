# Wax MCP Setup

## Pick a host

- **Claude Code only:** one-command below (stdio).
- **Codex, Cursor, Hermes, or more than one client:** one shared HTTP server, then a per-host snippet. See [wax-mcp-hosts.md](wax-mcp-hosts.md).

## One-command install into Claude Code

From a checkout (this is the real Claude registrar):

```bash
swift run --traits MCPServer wax-cli mcp install --scope user
```

This will:

1. Build or stage `wax-mcp` (bundled npm runtime is staged into a stable path)
2. Register a `wax` MCP server entry in Claude Code against the resolved `wax-mcp` binary
3. Configure default store paths under `~/.wax`
4. Stage the **wax-mcp operator skill** under `~/.local/share/waxmcp/skills/wax-mcp`
5. Attempt `claude install-skill` for that staged skill (best-effort)
6. Print a pasteable `CLAUDE.md` / `AGENTS.md` project-rules block as fallback

Skip skill staging with `--skip-skill` if you only want the MCP server.

The npm launcher (`npx waxmcp`) **serves** MCP. It does not implement `mcp install --scope`. Use `wax-cli mcp install` for Claude, or [wax-mcp-hosts.md](wax-mcp-hosts.md) for everyone else.

## How agents learn the playbook

Wax teaches agents at three layers:

| Layer | When it applies | What it teaches |
|-------|-----------------|-----------------|
| MCP `instructions` + tool descriptions | Every connected host | Session lifecycle, anti-patterns |
| `wax-mcp` skill | Hosts that load skills | Full operator playbook + install notes |
| Project rules (`CLAUDE.md` / `AGENTS.md`) | Always-on project instructions | Same workflow rules as a paste block |

You usually only need the Claude one-command, or the HTTP + host snippet in [wax-mcp-hosts.md](wax-mcp-hosts.md). Use the skill or project rules when the host ignores MCP instructions.

### Skill: agent operator vs Swift framework

| Skill | Path | Audience |
|-------|------|----------|
| `wax-mcp` | `Resources/skills/public/wax-mcp` | Agents *using* MCP memory tools |
| `wax` | `Resources/skills/public/wax` | Developers writing Swift Wax code |

```bash
# Operator skill (MCP tools)
claude install-skill ~/.local/share/waxmcp/skills/wax-mcp
# or
claude install-skill https://github.com/christopherkarani/Wax/tree/main/Resources/skills/public/wax-mcp

# Swift framework skill (optional, separate)
claude install-skill https://github.com/christopherkarani/Wax/tree/main/Resources/skills/public/wax
```

The published `waxmcp` npm package also ships `skills/wax-mcp` so installs do not require cloning this monorepo.

## Recommended project rules

Do not invent a third playbook. Copy the fences from
[`Resources/skills/public/wax-mcp/references/project-rules.md`](../skills/public/wax-mcp/references/project-rules.md):

- **AGENTS.md / CLAUDE.md / Cursor rules** — full operator block
- **Hermes / OpenClaw `SOUL.md`** — short Memory section; append, do not replace the soul

The README [Agent Quick Start](../../README.md#agent-quick-start) shows both as copy-paste `<details>`.

## Run doctor

```bash
npx -y waxmcp@latest mcp doctor
# or from a local build:
swift run --traits MCPServer wax-cli mcp doctor
```

## Manual serve

```bash
swift run --traits MCPServer wax-cli mcp serve
```

## Feature flags

- `WAX_MCP_FEATURE_LICENSE=0` (default): license validation disabled
- `WAX_MCP_FEATURE_LICENSE=1`: enable `LicenseValidator`
- `WAX_MCP_FEATURE_STRUCTURED_MEMORY=1` (default): enable graph/entity/fact tools
- `WAX_MCP_FEATURE_STRUCTURED_MEMORY=0`: disable structured memory graph tools
- `WAX_MCP_FEATURE_ACCESS_STATS=1` (default): enable access-stat recording + retrieval scoring
- `WAX_MCP_FEATURE_ACCESS_STATS=0`: disable access-stat-based scoring persistence

## MCP tool highlights

- Session lifecycle: `session_start`, `session_end`
- Session scoping on reads: `recall` and `search` accept `session_id`
- Explicit session scoping on writes: `remember` and `handoff` accept `session_id`
- Handoff continuity: `handoff`, `handoff_latest`
- Cross-session retrieval: `corpus_search` searches broker-managed session history and returns provenance metadata
- Structured memory graph: `entity_upsert`, `fact_assert`, `fact_retract`, `facts_query`, `entity_resolve`

## npx launcher

The npm launcher is at `npm/waxmcp` (package name `waxmcp`).

```bash
npx -y waxmcp@latest mcp serve
```

This package includes embedded binaries for:

1. `dist/darwin-arm64/wax-cli` + `dist/darwin-arm64/wax-mcp`
2. `dist/darwin-x64/wax-cli` + `dist/darwin-x64/wax-mcp`

and the operator skill at:

3. `skills/wax-mcp/`

For users of the published package, no local Wax build is required.
Stage binaries with `npx -y waxmcp@latest install`, then either
`swift run --traits MCPServer wax-cli mcp install --scope user` (Claude stdio)
or the shared HTTP path in [wax-mcp-hosts.md](wax-mcp-hosts.md).
Steady-state sessions should call the staged `wax-mcp` binary, not raw `npx`.

For local development:

```bash
export WAX_CLI_BIN=/Users/chriskarani/CodingProjects/AIStack/Wax/.build/debug/wax-cli
npx --yes /Users/chriskarani/CodingProjects/AIStack/Wax/npm/waxmcp mcp doctor
```

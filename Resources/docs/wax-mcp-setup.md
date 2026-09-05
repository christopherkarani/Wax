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
- **OpenClaw `SOUL.md`** — short Memory section; append, do not replace the soul
- **Native Hermes** — do not paste the MCP `session_open` loop. `memory.provider: wax-memory` owns lifecycle; call `wax_remember` / `wax_recall`.

The README [Agent Quick Start](../../README.md#agent-quick-start) shows both as copy-paste `<details>`.

## Run doctor

```bash
npx -y waxmcp@latest doctor
# or from a local build:
swift run --traits MCPServer wax-cli mcp doctor
# staged CLI after `waxmcp install`:
# ~/.local/share/waxmcp/runtime/darwin-arm64/wax-cli mcp doctor
```

`doctor` is host-name agnostic. It smoke-checks the daily tool surface
(`session_open`, `remember`, `recall`, `session_close`, `stats`,
`memory_get`, `compact_context`, `session_resume`).

Shared HTTP (LaunchAgent or the persistent launcher) is a different check:

```bash
npx -y waxmcp@latest vector-health
```

Green only when both `vectorSearchEnabled` and `queryEmbeddingAvailable`
are true. After `waxmcp install`, restart HTTP if it is already a service —
do not start a second writer:

```bash
launchctl kickstart -k "gui/$(id -u)/ai.wax.mcp-http"
# or, if that LaunchAgent is not loaded:
# ~/.local/share/waxmcp/bin/start-wax-mcp-http.sh
```

Native Hermes (see [wax-mcp-hosts.md](wax-mcp-hosts.md)):
`memory.provider: wax-memory` only. Never `plugins.enabled`. After
`install-hermes-plugin` from this tree:

```bash
hermes wax-memory doctor
hermes plugins doctor wax-memory
```

Those two commands are the operator path. `hermes wax-memory` registers
`status`, `doctor`, and `config` only. A stale plugin copy fails discovery
or import until you reinstall it — do not add `wax-memory` to
`plugins.enabled` to make the subcommand appear.

## Manual serve

```bash
swift run --traits MCPServer wax-cli mcp serve
```

## Feature flags

- `WAX_MCP_FEATURE_LICENSE=0` (default): license validation disabled
- `WAX_MCP_FEATURE_LICENSE=1`: enable `LicenseValidator`
- `WAX_MCP_TOOLS=daily` (default): `tools/list` is the eight daily verbs
- `WAX_MCP_TOOLS=full`: list aliases, graph, and admin tools
- `WAX_MCP_FEATURE_STRUCTURED_MEMORY=1` (default): enable graph/entity/fact tools
- `WAX_MCP_FEATURE_STRUCTURED_MEMORY=0`: disable structured memory graph tools
- `WAX_MCP_FEATURE_ACCESS_STATS=1` (default): enable access-stat recording + retrieval scoring
- `WAX_MCP_FEATURE_ACCESS_STATS=0`: disable access-stat-based scoring persistence

## MCP tool highlights

- Default open: `session_open` (one-shot session_id + short handoff + optional recall). Do not start with `handoff_latest` then `session_start`.
- Daily `tools/list`: `session_open`, `remember`, `recall`, `session_close`, `stats`, `memory_get`, `compact_context`, `session_resume`. Set `WAX_MCP_TOOLS=full` for aliases, graph, and admin tools.
- Recall scope: omitted `scope` is current-project after project/repo resolution. Empty project recall is a miss — pass `scope=global` only when you intend the whole local store (person facts). Global is not an authorization boundary. Supplying both `project` and `repo` requires both exact tags.
- Session scoping on reads: `recall` accepts `session_id` (merges that session with durable memory under project scope)
- Writes: `remember` — `memory_type` selects the horizon; durable types stay durable even if `session_id` is present; `task_state` / `handoff` need `session_id`
- Close: `session_close` harvests; do not call `memory_promote` in the agent loop
- Cross-session retrieval (full catalog): `corpus_search`
- Structured memory graph (full catalog): `entity_upsert`, `fact_assert`, `fact_retract`, `facts_query`, `entity_resolve`
- Native Hermes uses `wax_remember` / `wax_recall` / `wax_stats` and does not take a model-visible Wax UUID.

## npx launcher

The npm launcher is at `Resources/npm/waxmcp` (package name `waxmcp`).

```bash
npx -y waxmcp@latest mcp serve
```

This package includes Apple Silicon binaries under `dist/darwin-arm64/` and
the operator skill at `skills/wax-mcp/`. `waxmcp install` stages both binaries,
the skill, the Hermes provider, a version manifest, and
`bin/start-wax-mcp-http.sh` under `~/.local/share/waxmcp`. It does not write
the `ai.wax.mcp-http` LaunchAgent; see [wax-mcp-hosts.md](wax-mcp-hosts.md).

For users of the published package, no local Wax build is required.
Stage binaries with `npx -y waxmcp@latest install`, then either
`swift run --traits MCPServer wax-cli mcp install --scope user` (Claude stdio)
or the shared HTTP path in [wax-mcp-hosts.md](wax-mcp-hosts.md).
Steady-state sessions should call the staged `wax-mcp` binary, not raw `npx`.

For local development:

```bash
export WAX_CLI_BIN=/path/to/Wax/.build/debug/wax-cli
npx --yes ./Resources/npm/waxmcp doctor
```

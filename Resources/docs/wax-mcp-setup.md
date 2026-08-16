# Wax MCP Setup

## One-command install into Claude Code

```bash
npx -y waxmcp@latest mcp install --scope user
```

From a local checkout (development):

```bash
swift run --traits MCPServer wax-cli mcp install --scope user
```

This will:

1. Build or stage `wax-mcp` (bundled npm runtime is staged into a stable path)
2. Register a `wax` MCP server entry in Claude Code against the resolved `wax-mcp` binary
3. Configure default store paths under `~/.wax`
4. Stage the **wax-mcp operator skill** under `~/.local/share/waxmcp/skills/wax-mcp`
5. Attempt `claude install-skill` for that staged skill (best-effort)
6. Print a pasteable project-rules block as fallback (same text as `Resources/skills/public/wax-mcp/references/project-rules.md`)

Skip skill staging with `--skip-skill` if you only want the MCP server.

## Operator playbook (single source of truth)

**Do not maintain a second conflicting essay of the session lifecycle.** The canonical
host-facing playbook is embedded in MCP connections from:

`Sources/WaxMCPServer/AgentInstructions.swift` (`MCPAgentInstructions`)

That text is what every connected agent receives as server `instructions`. Expand or
correct the lifecycle there first; then keep the skill and pasteable project-rules
aligned with it.

| Layer | When it applies | What it teaches |
|-------|-----------------|-----------------|
| MCP `instructions` (`AgentInstructions.swift`) | Every connected host | **SoT** session lifecycle + tool selection |
| `wax-mcp` skill | Hosts that load skills | Install notes + same playbook (must match SoT) |
| Project rules paste block | Always-on project instructions | Same workflow rules for `CLAUDE.md` / app `AGENTS.md` |

> Root repo `AGENTS.md` is for **public-repo hygiene** for contributors — do not overwrite
> it with the memory operator playbook.

You usually only need the MCP install. Use the skill or project rules when the host
ignores MCP instructions or you want stronger always-on enforcement.

### Intended primary search path

Per `AgentInstructions.swift` and tool descriptions:

- Prefer **`recall`** for assembled RAG context (default read path).
- Use **`search`** for raw ranked hits; prefer `mode: "hybrid"` unless a lexical text search is requested.

> Note: some wire paths currently default omitted `search` mode to `"text"`. Treat
> **hybrid as the intended primary** when semantic recall helps; aligning code defaults
> is tracked in Phase 4 ([#94](https://github.com/christopherkarani/Wax/issues/94)).

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

Paste the block in `Resources/skills/public/wax-mcp/references/project-rules.md` into
your repo prompt, `CLAUDE.md`, or app-level `AGENTS.md` after installing Wax. Keep that
file aligned with `AgentInstructions.swift` — do not fork a third copy here.

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
- `WAX_MCP_FEATURE_ACCESS_STATS=0` (default): disable access-stat-based scoring persistence
- `WAX_MCP_FEATURE_ACCESS_STATS=1`: enable access-stat recording + scoring path

## MCP tool highlights

Canonical list: `Sources/WaxMCPServer/ToolSchemas.swift` (no `photo_*` / `video_*` tools).

- Session lifecycle: `session_start`, `session_end`
- Session scoping on reads: `recall` and `search` accept `session_id`
- Explicit session scoping on writes: `remember` and `handoff` accept `session_id`
- Handoff continuity: `handoff`, `handoff_latest`
- Cross-session retrieval: `corpus_search` searches broker-managed session history and returns provenance metadata
- Structured memory graph: `entity_upsert`, `fact_assert`, `fact_retract`, `facts_query`, `entity_resolve`

## npx launcher

The npm launcher is at `Resources/npm/waxmcp` (package name `waxmcp`).

```bash
npx -y waxmcp@latest mcp serve
```

This package includes embedded binaries for:

1. `dist/darwin-arm64/wax-cli` + `dist/darwin-arm64/wax-mcp`
2. `dist/darwin-x64/wax-cli` + `dist/darwin-x64/wax-mcp`

and the operator skill at:

3. `skills/wax-mcp/`

For users of the published package, no local Wax build is required.
Running `npx -y waxmcp@latest mcp install --scope user` stages those bundled artifacts into a
stable local runtime directory and registers the staged `wax-mcp` binary, so steady-state
Claude/Codex sessions do not depend on raw `npx`.

For local development from a Wax checkout:

```bash
export WAX_CLI_BIN="$(pwd)/.build/debug/wax-cli"
npx --yes ./Resources/npm/waxmcp mcp doctor
```

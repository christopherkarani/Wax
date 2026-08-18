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
6. Print a pasteable `CLAUDE.md` / `AGENTS.md` project-rules block as fallback

Skip skill staging with `--skip-skill` if you only want the MCP server.

## How agents learn the playbook

Wax teaches agents at three layers:

| Layer | When it applies | What it teaches |
|-------|-----------------|-----------------|
| MCP `instructions` + tool descriptions | Every connected host | Session lifecycle, anti-patterns |
| `wax-mcp` skill | Hosts that load skills | Full operator playbook + install notes |
| Project rules (`CLAUDE.md` / `AGENTS.md`) | Always-on project instructions | Same workflow rules as a paste block |

You usually only need step 1. Use the skill or project rules when the host ignores MCP instructions or you want stronger always-on enforcement.

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

Paste this into your repo prompt, `CLAUDE.md`, or `AGENTS.md` after installing Wax:

```text
Use the Wax MCP server for persistent memory in this repo.

Workflow rules:
- At session start, call `handoff_latest` first to load prior context, then call `session_start` once and keep the returned `session_id`. Pass stable `agent_id` and `run_id` so a retry reuses the same session.
- Use `remember` to store decisions, discoveries, and short factual notes. If the memory is session-scoped, pass `session_id` as a top-level argument. Do not put `session_id` inside `metadata`.
- Use `recall` for assembled context and `search` for raw ranked hits. `recall` with `session_id` merges that session with durable long-term memory.
- Prefer `mode: "hybrid"` when semantic retrieval helps. Use `mode: "text"` when I want a fast or deterministic lexical lookup.
- Do not manage `SESSION_STORE`, `--store-path`, or `flush` in normal agent flows. The broker owns long-term memory and virtual session stores.
- Use `handoff` near the end of the session with `content`, optional `project`, and `pending_tasks`, then call `session_end`.
- Use `corpus_search` only when you need cross-session retrieval across broker-managed session history with provenance metadata.
- Use structured memory tools (`entity_upsert`, `fact_assert`, `fact_retract`, `facts_query`, `entity_resolve`) for stable entities and facts, not transient debugging notes.

Behavior expectations:
- Read existing handoffs and recall results before asking me to restate prior context.
- Keep memory writes concise, factual, and scoped to the task.
- When a cross-session result looks relevant, cite the provenance metadata so we know which session store it came from.
```

The same text ships in `Resources/skills/public/wax-mcp/references/project-rules.md`.

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
Running `npx -y waxmcp@latest mcp install --scope user` stages those bundled artifacts into a
stable local runtime directory and registers the staged `wax-mcp` binary, so steady-state
Claude/Codex sessions do not depend on raw `npx`.

For local development:

```bash
export WAX_CLI_BIN=/Users/chriskarani/CodingProjects/AIStack/Wax/.build/debug/wax-cli
npx --yes /Users/chriskarani/CodingProjects/AIStack/Wax/npm/waxmcp mcp doctor
```

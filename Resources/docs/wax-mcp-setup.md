# Wax MCP Setup

Wax exposes an MCP server with unprefixed tool names such as `session_start`,
`remember`, `recall`, `search`, `handoff`, and `session_end`.

## Codex Install

```bash
npx -y waxmcp@latest mcp install --scope user
```

Then add the memory workflow to `AGENTS.md`:

```text
Use the Wax MCP server for persistent memory in this repo.

Workflow rules:
- At session start, call `handoff_latest` first to load prior context, then call `session_start` once and keep the returned `session_id`.
- Use `remember` to store decisions, discoveries, and short factual notes. If the memory is session-scoped, pass `session_id` as a top-level argument. Do not put `session_id` inside `metadata`.
- Use `recall` for assembled context and `search` for raw ranked hits.
- Prefer `mode: "hybrid"` when semantic retrieval helps. Use `mode: "text"` when I want a fast or deterministic lexical lookup.
- Do not manage `SESSION_STORE`, `--store-path`, or `flush` in normal agent flows. The broker owns long-term memory and virtual session stores; `flush` is an advanced operator/debugging tool.
- Use `handoff` near the end of the session with `content`, optional `project`, `pending_tasks`, and optional `session_id`, then call `session_end`.
- Use `corpus_search` only when you need cross-session retrieval across broker-managed session history with provenance metadata.
- Use structured memory tools (`entity_upsert`, `fact_assert`, `fact_retract`, `facts_query`, `entity_resolve`) for stable entities and facts, not transient debugging notes.

Behavior expectations:
- Read existing handoffs and recall results before asking me to restate prior context.
- Keep memory writes concise, factual, and scoped to the task.
- When a cross-session result looks relevant, cite the provenance metadata so we know which session store it came from.
```

## Claude Code Install

```bash
npx -y waxmcp@latest mcp install --scope user
```

Then add the same workflow to `CLAUDE.md`. Claude Code users can also install
the Wax skill:

```bash
claude install-skill https://github.com/christopherkarani/Wax/tree/main/Resources/skills/public/wax
```

## Local Development Install

From this checkout:

```bash
cd /Users/chriskarani/CodingProjects/AIStack/Agents/Wax
swift run --traits MCPServer wax-cli mcp install --scope user
```

This will:

1. Build `wax-mcp`
2. Register a `wax` MCP server entry against the resolved `wax-mcp` binary
3. Configure default store paths under `~/.wax`

## Run Doctor

```bash
npx -y waxmcp@latest mcp doctor
```

For local development:

```bash
cd /Users/chriskarani/CodingProjects/AIStack/Agents/Wax
swift run --traits MCPServer wax-cli mcp doctor
```

## Manual Serve

```bash
npx -y waxmcp@latest mcp serve
```

For local development:

```bash
cd /Users/chriskarani/CodingProjects/AIStack/Agents/Wax
swift run --traits MCPServer wax-cli mcp serve
```

## HTTP Transport

HTTP transport is useful for local gateway testing and colocated OpenClaw
deployments:

```bash
wax-mcp --no-embedder --transport http --http-host 127.0.0.1 --http-port 3000 --http-endpoint /mcp
```

The built-in HTTP listener is local-only by default. Do not bind it to a public
interface unless an authenticated gateway provides rate limits, TLS, and network
access controls. For local gateway deployments, `wax-mcp` also supports
`--http-auth-token` / `WAX_MCP_HTTP_AUTH_TOKEN` and
`--http-max-body-bytes` / `WAX_MCP_HTTP_MAX_BODY_BYTES`:

```bash
WAX_MCP_HTTP_AUTH_TOKEN="$(openssl rand -hex 32)" \
wax-mcp --no-embedder --transport http --http-host 127.0.0.1 --http-port 3000 --http-endpoint /mcp --http-max-body-bytes 1048576
```

## Feature Flags

- `WAX_MCP_FEATURE_LICENSE=0` (default): license validation disabled
- `WAX_MCP_FEATURE_LICENSE=1`: enable `LicenseValidator`
- `WAX_MCP_FEATURE_STRUCTURED_MEMORY=1` (default): enable graph/entity/fact tools
- `WAX_MCP_FEATURE_STRUCTURED_MEMORY=0`: disable structured memory graph tools
- `WAX_MCP_FEATURE_ACCESS_STATS=0` (default): disable access-stat-based scoring persistence
- `WAX_MCP_FEATURE_ACCESS_STATS=1`: enable access-stat recording + scoring path

## MCP Tool Highlights

- Session lifecycle: `session_start`, `session_end`
- Session scoping on reads: `recall` and `search` accept `session_id`
- Explicit session scoping on writes: `remember` and `handoff` accept `session_id`
- Handoff continuity: `handoff`, `handoff_latest`
- Cross-session retrieval: `corpus_search` searches broker-managed session history and returns provenance metadata
- Structured memory graph: `entity_upsert`, `fact_assert`, `fact_retract`, `facts_query`, `entity_resolve`

## npm Launcher

The npm launcher is published as `waxmcp`.

```bash
npx -y waxmcp@latest mcp serve
```

The package includes embedded `wax-cli` and `wax-mcp` binaries for supported
Darwin architectures. For users of the published package, no local Wax build is
required. Running `npx -y waxmcp@latest mcp install --scope user` stages bundled
artifacts into a stable local runtime directory, so steady-state Codex and
Claude Code sessions do not depend on raw `npx` startup.

# Wax MCP Setup

## One-command install into Claude Code

```bash
cd /Users/chriskarani/CodingProjects/AIStack/Wax
swift run WaxCLI mcp install --scope user
```

This will:

1. Build `WaxMCPServer`
2. Register a `wax` MCP server entry in Claude Code
3. Configure default store paths under `~/.wax`

## Run doctor

```bash
swift run WaxCLI mcp doctor
```

## Manual serve

```bash
swift run WaxCLI mcp serve
```

## Feature flags

- `WAX_MCP_FEATURE_LICENSE=0` (default): license validation disabled
- `WAX_MCP_FEATURE_LICENSE=1`: enable `LicenseValidator`
- `WAX_MCP_FEATURE_STRUCTURED_MEMORY=1` (default): enable graph/entity/fact tools
- `WAX_MCP_FEATURE_STRUCTURED_MEMORY=0`: disable structured memory graph tools
- `WAX_MCP_FEATURE_ACCESS_STATS=0` (default): disable access-stat-based scoring persistence
- `WAX_MCP_FEATURE_ACCESS_STATS=1`: enable access-stat recording + scoring path

## MCP tool highlights

- Session lifecycle: `wax_session_start`, `wax_session_end`
- Session scoping on reads: `wax_recall` and `wax_search` accept `session_id`
- Explicit session scoping on writes: `wax_remember` and `wax_handoff` accept `session_id`
- Handoff continuity: `wax_handoff`, `wax_handoff_latest`
- Structured memory graph: `wax_entity_upsert`, `wax_fact_assert`, `wax_fact_retract`, `wax_facts_query`, `wax_entity_resolve`
- Batched graph mutation option: set `commit=false` on graph mutations and call `wax_flush` to commit once

## npx launcher

The npm launcher is at `npm/waxmcp`.

```bash
npx -y waxmcp@latest mcp serve
```

This package includes embedded `WaxCLI` binaries for:

1. `dist/darwin-arm64/WaxCLI`
2. `dist/darwin-x64/WaxCLI`

For users of the published package, no local Wax build is required.

For local development:

```bash
export WAX_CLI_BIN=/Users/chriskarani/CodingProjects/AIStack/Wax/.build/debug/WaxCLI
npx --yes /Users/chriskarani/CodingProjects/AIStack/Wax/npm/waxmcp mcp doctor
```

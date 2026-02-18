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

## npx launcher

The npm launcher is at `npm/waxmcp`.

```bash
npx -y waxmcp@latest mcp serve
```

For local development:

```bash
export WAX_CLI_BIN=/Users/chriskarani/CodingProjects/AIStack/Wax/.build/debug/WaxCLI
npx --yes /Users/chriskarani/CodingProjects/AIStack/Wax/npm/waxmcp mcp doctor
```

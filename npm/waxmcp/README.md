# waxmcp

`waxmcp` is an npm launcher for the Wax MCP server.

## Usage

```bash
npx -y waxmcp@latest mcp serve
```

By default, the launcher tries these commands in order:

1. `$WAX_CLI_BIN`
2. `wax`
3. `WaxCLI`
4. `./.build/debug/WaxCLI` (current working directory)

## Local development

```bash
cd /path/to/Wax
swift build --product WaxCLI --traits MCPServer
export WAX_CLI_BIN=/path/to/Wax/.build/debug/WaxCLI
npx --yes ./npm/waxmcp mcp doctor
```

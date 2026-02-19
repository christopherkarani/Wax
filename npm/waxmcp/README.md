# waxmcp

`waxmcp` is an npm launcher for the Wax MCP server.

## Usage

```bash
npx -y waxmcp@latest mcp serve
```

To publish a new version:

```bash
cd /path/to/Wax/npm/waxmcp
npm version patch   # or minor/major/1.2.3
npm publish --access public
```

By default, the launcher uses this order:

1. `$WAX_CLI_BIN`
2. Bundled `dist/darwin-arm64/WaxCLI` or `dist/darwin-x64/WaxCLI`
3. `wax`
4. `WaxCLI`
5. `./.build/debug/WaxCLI` (current working directory)

## Local development

```bash
cd /path/to/Wax
swift build --product WaxCLI --traits MCPServer
export WAX_CLI_BIN=/path/to/Wax/.build/debug/WaxCLI
npx --yes ./npm/waxmcp mcp doctor
```

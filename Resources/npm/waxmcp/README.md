# WAX

[![Discord](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fdiscord.com%2Fapi%2Fv10%2Finvites%2FNHgNh7HJ6M%3Fwith_counts%3Dtrue&query=%24.approximate_presence_count&suffix=%20online&logo=discord&label=Discord&color=5865F2)](https://discord.gg/NHgNh7HJ6M)

One shared memory for your entire agent team.

Grok Bot, Claude Code, Codex, Cursor, and any other MCP-compatible agent read
and write the same durable store: a single `.wax` file on your machine.
Decisions, facts, and session handoffs survive across agents, sessions, tools,
and reboots.

WAX is local, portable, and inspectable. No cloud account, no hosted database.
MCP is just the transport your agents use to reach the store; the product is
the shared memory itself.

## Install

```bash
npx -y waxmcp@latest mcp serve
```

This starts a WAX MCP server over stdio against `~/.wax/memory.wax`. Register
that command as an MCP server in your agent host and it gets the full tool set:
`remember`, `recall`, `search`, `session_open`, `handoff_latest`, `stats`.

Running more than one agent at a time? Start exactly one HTTP server and point
every host at the same URL:

```bash
npx -y waxmcp@latest \
  --transport http \
  --http-host 127.0.0.1 \
  --http-port 3000 \
  --http-endpoint /mcp \
  --embedder minilm
```

A second server pointed at the same `.wax` file will hit the store lock, so one
shared HTTP endpoint is the right shape for multi-agent setups.

## How it works

```
Claude Code ─┐
Codex ───────┤
Cursor ──────┼─→  WAX runtime  ─→  one ~/.wax/memory.wax file
Grok Bot ────┘     (MCP stdio
                    or HTTP)
```

Every agent connects through MCP. Every tool call lands in the same runtime,
which serializes access to a single `.wax` file. What that buys you:

- **Shared context across agents.** A decision written by one agent is
  retrievable by every other agent on the machine.
- **Persistence across sessions.** Memory outlives chats, restarts, and tool
  switches by default.
- **User-owned storage.** One plain file under your home directory. Inspect it,
  back it up, sync it with iCloud or AirDrop, delete it whenever you like.
- **No cloud account required.** Everything runs locally on your hardware.
- **Portable across hosts.** Any MCP-compatible client works against the same
  endpoint, so swapping agents never means migrating memory.

WAX complements each host's native scratchpad memory. It does not replace it.

## Agent team example

One agent records a decision. Another agent, days later in a different repo,
retrieves it.

Monday, Claude Code closes out a refactor:

```json
{
  "tool": "remember",
  "arguments": {
    "content": "Decision: auth middleware runs before rate limiting in shop-api. Reversing them breaks checkout tests.",
    "project": "shop-api",
    "memory_type": "decision",
    "durability": "durable"
  }
}
```

Thursday, Codex debugs checkout from another workspace:

```json
{
  "tool": "recall",
  "arguments": {
    "query": "middleware order auth rate limit",
    "project": "shop-api"
  }
}
```

The response contains Monday's decision with its provenance. Nobody re-derives
the middleware order or argues with a stale assumption.

## Wiring up your hosts

Host-by-host configuration for Claude Code, Codex, Cursor, Hermes, and generic
MCP clients lives in
[Resources/docs/wax-mcp-hosts.md](https://github.com/christopherkarani/Wax/blob/main/Resources/docs/wax-mcp-hosts.md).

### Claude Code

From a Wax checkout, `wax-cli` is the registrar:

```bash
swift run --traits MCPServer wax-cli mcp install --scope user
```

That command stages the runtime under `~/.local/share/waxmcp`, registers the
server with Claude Code via `claude mcp add`, stages the operator skill to
`~/.local/share/waxmcp/skills/wax-mcp`, and runs `claude install-skill` when
available. If skill auto-install did not run:

```bash
claude install-skill ~/.local/share/waxmcp/skills/wax-mcp
```

If you already run the shared HTTP server, register the URL instead of stdio.
The hosts doc shows the exact snippet per host.

Two skills ship in this ecosystem. `wax-mcp` is the operator playbook for using
the memory tools. The separate `wax` skill (in the monorepo) covers Swift
framework integration.

## Launcher reference

`waxmcp` wraps the native binaries (`wax-mcp` server and `wax-cli`) and resolves
them in this order:

1. `$WAX_MCP_BIN` or `$WAX_CLI_BIN`
2. Bundled `dist/darwin-arm64/` binaries
3. Same-named binary on `PATH`
4. `./.build/debug/<binary>` in the current working directory

| Command | Purpose |
|---|---|
| `npx -y waxmcp@latest mcp serve` | Serve MCP over stdio |
| `npx -y waxmcp@latest --transport http ...` | Serve MCP over HTTP for multi-agent setups |
| `npx -y waxmcp@latest mcp doctor` | Validate setup and run a tools/list smoke check |
| `npx -y waxmcp@latest vector-health` | Check vector search status of the HTTP endpoint |
| `npx -y waxmcp@latest task-state-migrate --direct-store --store-path ~/.wax/memory.wax --destination-path /tmp/repaired.wax --dry-run` | Report and repair legacy durable `task_state` frames into a distinct, complete store copy |
| `npx -y waxmcp@latest install` | Locate or build (`--build`) the `wax-mcp` binary |
| `npx -y waxmcp@latest install-hermes-plugin` | Install the Hermes wax-memory plugin |
| `npx -y waxmcp@latest install-openclaw-plugin` | Print OpenClaw plugin install steps |
| `npx -y waxmcp@latest install-all-plugins` | Install all plugins |

### Configuration

| Setting | How |
|---|---|
| Store path | `--store-path <path>` (default `~/.wax/memory.wax`) |
| Embedder | `--embedder minilm` or `--embedder arctic`; omit and the launcher defaults to arctic |
| Text-only mode | `--no-embedder` |
| Binary override | `WAX_MCP_BIN` / `WAX_CLI_BIN` environment variables |
| Endpoint override | `WAX_MCP_HTTP_PORT` / `WAX_MCP_HTTP_ENDPOINT` (used by `vector-health`) |

Vector search needs both binaries built with embedder traits; the bundled npm
artifacts already are. Without an embedder, search runs text-only.

## Platform support

The bundled npm runtime ships `darwin-arm64` artifacts (Apple Silicon). Intel
Mac builds are not packaged because MetalANNS Float16 requires Apple Silicon.
The underlying server builds from source on macOS and Linux, including HTTP
transport for gateway deployments.

## Local development

```bash
cd /path/to/Wax
swift build --product wax-cli --traits MCPServer
swift build --product wax-mcp --traits MCPServer
export WAX_CLI_BIN=/path/to/Wax/.build/debug/wax-cli
npx --yes ./Resources/npm/waxmcp mcp doctor
```

## Maintainers

Release with the version sync script. It bumps `package.json`, the MCP server
version, and the CLI version together, then rebuilds the Darwin binaries:

```bash
cd /path/to/Wax
./Resources/scripts/release-waxmcp.sh 0.1.33
git add Resources/npm/waxmcp/package.json Sources/WaxMCPServer/main.swift Sources/WaxCLI/WaxCLICommand.swift Resources/npm/waxmcp/dist
git commit -m "release: bump waxmcp version"
```

Pushing tag `waxmcp-v<version>` triggers the publish workflow
(`.github/workflows/release-waxmcp.yml`). That workflow also finalizes the
Homebrew formula `sha256` from the GitHub tag archive and commits it back to
`main`. Set repository secret `HOMEBREW_TAP_TOKEN` (PAT with `contents: write`
on `christopherkarani/homebrew-wax`) to sync the external tap automatically.
`package.json` and `Sources/WaxMCPServer/main.swift` must stay in lockstep; CI
checks that before publishing. Dist artifacts carry `sha256` checksums,
verified at pack time by `scripts/verify-dist.mjs`.

# Wax Memory Plugin for Hermes Agent

Native Hermes memory provider backed by [Wax](https://github.com/christopherkarani/Wax) MCP over HTTP.

## Quick Start (3 steps)

```bash
# 1. Build Wax MCP with vector search
swift build --product wax-mcp --traits "MiniLMEmbeddings,ArcticEmbeddings,MCPServer"
swift build --product wax-cli --traits "MiniLMEmbeddings,ArcticEmbeddings"

# 2. Copy plugin to Hermes
cp -r /path/to/wax-memory-plugin ~/.hermes/plugins/wax-memory

# 3. Enable in Hermes config
hermes config set memory.provider wax-memory
```

That's it. Start `hermes` and Wax memory works — including **vector/semantic search**.

## Prerequisites

A Wax MCP HTTP server must be running:

```bash
# Terminal 1 — start Wax MCP
.build/debug/wax-mcp --embedder minilm --transport http --http-host 127.0.0.1 --http-port 3000
```

Or use the npm wrapper (if installed):

```bash
npx waxmcp --embedder minilm --transport http
```

## Vector Search

Vector search is **automatic** when the Wax MCP server is built and started with an embedder:

```bash
# Build with embedders (both wax-cli broker + wax-mcp server)
swift build --product wax-cli --traits "MiniLMEmbeddings,ArcticEmbeddings"
swift build --product wax-mcp --traits "MiniLMEmbeddings,ArcticEmbeddings,MCPServer"

# Start with an embedder
.build/debug/wax-mcp --embedder minilm --transport http
```

### Verify Vector Search

```bash
# Via npm wrapper
npx waxmcp vector-health

# Or via the plugin's stats tool inside Hermes
# The plugin will log vector search status on startup
```

### Common Issue: "Vector search is disabled"

This happens when `wax-mcp` spawns a `wax-cli` broker that wasn't built with embedders. **Both binaries need embedder support.**

**Fix:**
```bash
# Rebuild BOTH binaries with embedders
swift build --product wax-cli --traits "MiniLMEmbeddings,ArcticEmbeddings"
swift build --product wax-mcp --traits "MiniLMEmbeddings,ArcticEmbeddings,MCPServer"
```

## Configuration

Add to `~/.hermes/config.yaml`:

```yaml
memory:
  provider: wax-memory

plugins:
  enabled:
  - wax-memory
```

### Environment Variables

| Variable | Description |
|----------|-------------|
| `WAX_MCP_HTTP_ENDPOINT` | Wax MCP HTTP endpoint (default: `http://127.0.0.1:3000/mcp`) |
| `WAX_MCP_AUTO_START` | Set to `1` to auto-start wax-mcp if not running |
| `WAX_STRUCTURED_MEMORY` | Enable structured memory tools (`1` or `0`, default `1`) |

## Tools Exposed

| Tool | Description |
|------|-------------|
| `wax_remember` | Store memory (text + optional metadata) |
| `wax_recall` | RAG-based context recall with `mode: vector/hybrid/text` |
| `wax_search` | Direct ranked search |
| `wax_handoff` | Write cross-session handoff note |
| `wax_handoff_latest` | Read latest handoff |
| `wax_compact_context` | Token-budgeted memory checkpoint |
| `wax_markdown_export` | Export MEMORY.md / daily notes |
| `wax_markdown_sync` | Import/reconcile Markdown |
| `wax_stats` | Runtime diagnostics |
| `wax_session_start` / `wax_session_end` | Session lifecycle |
| `wax_entity_upsert` | Upsert typed entity (structured memory) |
| `wax_fact_assert` | Assert fact triple (structured memory) |
| `wax_facts_query` | Query triplestore (structured memory) |

## Architecture

```
Hermes Agent
  └── WaxMemoryProvider (this plugin)
        └── HTTP SSE ──► wax-mcp (MCP server)
              └── Unix socket ──► wax-cli daemon (broker)
                    └── ~/.wax/memory.wax (SQLite + vector index)
```

The plugin handles:
- SSE session management with Wax MCP
- Auto-detection of vector search capability
- Clear diagnostics when things go wrong
- Optional auto-start of wax-mcp

## Files

- `plugin.yaml` — Hermes plugin manifest
- `hermes_wax_memory.py` — MemoryProvider + SSE client + MCP manager
- `__init__.py` — Plugin entrypoint
- `pyproject.toml` — Pip distributable

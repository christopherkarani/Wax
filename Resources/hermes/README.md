# Wax Integration for Hermes Agent

Hermes Agent supports both **MCP servers** (generic tool extension) and **native Python plugins** (first-class MemoryProvider interface). This directory provides both approaches.

| Approach | Use When | Integration Depth |
|---|---|---|
| [Native Plugin](#native-memory-provider-plugin-recommended) | Wax as canonical memory backend | Full `MemoryProvider` + lifecycle hooks |
| [MCP Server](#mcp-server-quick-start) | Quick tool access without plugin code | Tools appear alongside built-ins |

---

## Native Memory Provider Plugin (Recommended)

Install Wax as Hermes' **native memory provider** so it handles cross-session persistence, automatic `on_session_end` handoff writes, and Markdown artifact export.

### Prerequisites

Build Wax MCP with **vector search** support:

```bash
cd /path/to/Wax
swift build --product wax-cli --traits "MiniLMEmbeddings,ArcticEmbeddings"
swift build --product wax-mcp --traits "MiniLMEmbeddings,ArcticEmbeddings,MCPServer"
```

> **Note:** Both `wax-cli` (broker) and `wax-mcp` (server) need embedder support. If only one has it, vector search silently falls back to text-only.

Start the Wax MCP server:

```bash
.build/debug/wax-mcp --embedder minilm --transport http --http-host 127.0.0.1 --http-port 3000
```

### Install

**Directory plugin (local / development):**

```bash
cp -r /path/to/Resources/hermes/wax-memory-plugin "$HERMES_HOME/plugins/wax-memory"
```

`npx waxmcp install-hermes-plugin` copies the same files into `$HERMES_HOME/plugins/wax-memory` (or `~/.hermes` when `HERMES_HOME` is unset).

**Pip install (distributable):**

```bash
pip install ./Resources/hermes/wax-memory-plugin
```

The package entry point is `hermes_agent.memory_providers` → `hermes_wax_memory:register`.

### Enable

Add to `$HERMES_HOME/config.yaml`:

```yaml
memory:
  provider: wax-memory
```

Memory providers are exclusive. Do not add `wax-memory` to `plugins.enabled`.

Or set the environment variable:

```bash
export WAX_MCP_HTTP_ENDPOINT="http://127.0.0.1:3000/mcp"
export WAX_STRUCTURED_MEMORY=1   # optional
```

### What You Get

- `MemoryProvider` interface — Wax is the canonical memory backend
- `on_session_end` / `on_session_switch` — session-correct handoff and resume
- Background prefetch and turn sync so recall does not block Hermes
- Native tool schemas for core Wax MCP tools
- Optional structured memory tools when `WAX_STRUCTURED_MEMORY=1`
- Vector search via `mode: vector` or `mode: hybrid`
- `hermes wax-memory doctor` for broker and embedder diagnostics

### Verify Vector Search

```bash
npx waxmcp vector-health
hermes wax-memory doctor
```

See [`wax-memory-plugin/README.md`](./wax-memory-plugin/README.md) for the tool reference and configuration.

---

## MCP Server (Quick Start)

If you prefer the lighter MCP-only approach, add Wax as an `mcp_servers` entry in Hermes config.

Add to your Hermes `$HERMES_HOME/config.yaml`:

```yaml
mcp_servers:
  wax-memory:
    command: "npx"
    args: ["-y", "waxmcp@0.1.37", "mcp", "serve"]
    env:
      WAX_MCP_FEATURE_LICENSE: "0"
      WAX_MCP_FEATURE_STRUCTURED_MEMORY: "1"
    enabled: true
    timeout: 120
    tools:
      include: [remember, recall, search, handoff, handoff_latest, session_start, session_end]
      resources: false
      prompts: false
```

### Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `command` | `npx` | Launcher for waxmcp |
| `args` | `["-y", "waxmcp@0.1.37", "mcp", "serve"]` | Arguments passed to waxmcp |
| `env.WAX_MCP_FEATURE_LICENSE` | `"0"` | Disable license checks |
| `env.WAX_MCP_FEATURE_STRUCTURED_MEMORY` | `"1"` | Enable structured memory tools |
| `timeout` | `120` | MCP call timeout in seconds |
| `tools.include` | all tools | Whitelist of Wax tools to expose |

**Note:** MCP mode gives Hermes tools but no instruction on when to use them proactively. Without behavioral guidance, the LLM may recall but never save. The native memory provider plugin solves this by implementing `MemoryProvider` and adding lifecycle hooks.

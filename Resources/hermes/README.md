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
cp -r /path/to/Resources/hermes/wax-memory-plugin ~/.hermes/plugins/wax-memory
```

**Pip install (distributable):**

```bash
pip install ./Resources/hermes/wax-memory-plugin
```

### Enable

Add to `~/.hermes/config.yaml`:

```yaml
memory:
  provider: wax-memory

plugins:
  enabled:
  - wax-memory
```

Or set the environment variable:

```bash
export WAX_MCP_HTTP_ENDPOINT="http://127.0.0.1:3000/mcp"
export WAX_STRUCTURED_MEMORY=1   # optional
```

### What You Get

- `MemoryProvider` interface — Wax is the canonical memory backend
- `on_session_end` hook — auto-persists session summary + handoff into Wax
- Native tool schemas for all Wax MCP tools (`remember`, `recall`, `search`, `handoff`, `compact_context`, `markdown_export`, `markdown_sync`, `stats`, `session_start`, `session_end`)
- Optional structured memory tools (`entity_upsert`, `fact_assert`, `facts_query`) when `WAX_STRUCTURED_MEMORY=1`
- **Vector search** — semantic recall via `mode: vector` or `mode: hybrid`
- Auto-detection + clear diagnostics when vector search is unavailable

### Verify Vector Search

```bash
# Via npm wrapper
npx waxmcp vector-health

# Or check the plugin loads with vector search
python3 -c "
import sys, os
sys.path.insert(0, os.path.expanduser('~/.hermes/hermes-agent'))
from plugins.memory import load_memory_provider
p = load_memory_provider('wax-memory')
print('Available:', p.is_available())
result = json.loads(p.handle_tool_call('wax_stats', {}))
stats = json.loads(result['text'])
print('Vector search:', stats.get('vectorSearchEnabled'))
print('Embedder:', stats.get('embedder'))
"
```

See [`wax-memory-plugin/README.md`](./wax-memory-plugin/README.md) for full tool reference and configuration.

---

## MCP Server (Quick Start)

If you prefer the lighter MCP-only approach, add Wax as an `mcp_servers` entry in Hermes config.

Add to your Hermes `~/.hermes/config.yaml`:

```yaml
mcp_servers:
  wax-memory:
    command: "npx"
    args: ["-y", "waxmcp@0.1.24", "mcp", "serve"]
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
| `args` | `["-y", "waxmcp@0.1.24", "mcp", "serve"]` | Arguments passed to waxmcp |
| `env.WAX_MCP_FEATURE_LICENSE` | `"0"` | Disable license checks |
| `env.WAX_MCP_FEATURE_STRUCTURED_MEMORY` | `"1""` | Enable structured memory tools |
| `timeout` | `120` | MCP call timeout in seconds |
| `tools.include` | all tools | Whitelist of Wax tools to expose |

**Note:** MCP mode gives Hermes tools but no instruction on when to use them proactively. Without behavioral guidance, the LLM may recall but never save. The native memory provider plugin solves this by implementing `MemoryProvider` and adding lifecycle hooks.

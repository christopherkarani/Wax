# Wax Memory Plugin for Hermes Agent

Native Hermes memory provider backed by [Wax](https://github.com/christopherkarani/Wax) MCP over HTTP.

## Quick Start

```bash
# 1. Start Wax MCP with vector search
npx waxmcp --embedder minilm --transport http

# 2. Install the plugin into the active Hermes profile
npx waxmcp install-hermes-plugin
# or: cp -r Resources/hermes/wax-memory-plugin "$HERMES_HOME/plugins/wax-memory"

# 3. Select Wax as the exclusive memory provider
hermes config set memory.provider wax-memory
```

Do not add `wax-memory` to `plugins.enabled`. Memory providers are selected only by `memory.provider`.

## Pip install

```bash
pip install ./Resources/hermes/wax-memory-plugin
hermes config set memory.provider wax-memory
```

The package registers under `hermes_agent.memory_providers`.

## Configuration

`hermes memory setup` writes non-secret settings to `$HERMES_HOME/wax-memory.json`.

Resolution order for the MCP endpoint:

1. `WAX_MCP_HTTP_ENDPOINT`
2. `$HERMES_HOME/wax-memory.json` `endpoint`
3. `http://127.0.0.1:3000/mcp`

| Variable | Description |
|----------|-------------|
| `WAX_MCP_HTTP_ENDPOINT` | Wax MCP HTTP endpoint |
| `WAX_MCP_AUTO_START` | Set to `1` to auto-start `wax-mcp` during `initialize()` |
| `WAX_STRUCTURED_MEMORY` | Enable structured memory tools (`1` default) |
| `WAX_HERMES_EXTENDED_TOOLS` | Expose session/markdown/compact tools to the model |
| `WAX_STORE_PATH` | Extra path included in `hermes backup` |
| `HERMES_HOME` | Profile directory used by install and config |

```yaml
memory:
  provider: wax-memory
```

## Tools

Default tools stay small to avoid schema bloat:

| Tool | Description |
|------|-------------|
| `wax_remember` | Store memory (`memory_type`: note, task_state, user_preference, decision, lesson, handoff, constraint, fact); task_state requires an active session and is always working |
| `wax_recall` | RAG context recall |
| `wax_search` | Ranked raw hits |
| `wax_handoff` / `wax_handoff_latest` | Cross-session handoff |
| `wax_stats` | Runtime diagnostics |

Structured tools (`wax_entity_*`, `wax_fact_*`) are on by default. Session lifecycle stays inside the provider unless `WAX_HERMES_EXTENDED_TOOLS=1`.

## CLI

When this provider is active:

```bash
hermes wax-memory status
hermes wax-memory doctor
hermes wax-memory config
```

## Architecture

```
Hermes Agent
  └── WaxMemoryProvider
        └── HTTP MCP ──► wax-mcp
              └── Unix socket ──► wax-cli broker
                    └── ~/.wax/memory.wax
```

The provider implements the current Hermes `MemoryProvider` contract: local `is_available()`, background `sync_turn` / `queue_prefetch`, `on_session_switch`, `on_memory_write`, `recall_status`, and `backup_paths`.

# Wax Integration for Hermes Agent

Hermes Agent supports MCP (Model Context Protocol) servers for extending its capabilities. This directory provides the configuration and documentation for integrating Wax as a memory provider in Hermes.

## Quick Setup

Add to your Hermes `~/.hermes/config.yaml`:

```yaml
mcp_servers:
  wax-memory:
    command: "npx"
    args: ["-y", "waxmcp@0.1.22", "mcp", "serve"]
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

## Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `command` | `npx` | Launcher for waxmcp |
| `args` | `[
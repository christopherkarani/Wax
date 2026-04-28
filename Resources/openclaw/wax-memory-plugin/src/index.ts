import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { registerMemoryCapability } from "openclaw/plugin-sdk/memory-core";

const DEFAULT_HTTP_ENDPOINT = "http://127.0.0.1:3000/mcp";

export default definePluginEntry((api) => {
  registerMemoryCapability(api, {
    id: "wax-memory",
    displayName: "Wax Memory",
    description:
      "Uses the Wax MCP broker as the canonical memory runtime and exposes managed Markdown artifacts for MEMORY.md, daily notes, and DREAMS.md review.",
    publicArtifacts: {
      async listArtifacts() {
        return [
          {
            id: "wax-memory-md",
            label: "Wax MEMORY.md projection",
            kind: "markdown",
          },
          {
            id: "wax-dreams-md",
            label: "Wax DREAMS.md review queue",
            kind: "markdown",
          },
        ];
      },
    },
    runtime: {
      transport: "mcp-http",
      endpoint: api.pluginConfig?.endpoint ?? DEFAULT_HTTP_ENDPOINT,
      command: api.pluginConfig?.command ?? "wax-mcp",
      args: api.pluginConfig?.args ?? ["--no-embedder", "--transport", "http", "--http-port", "3000"],
    },
  });
});

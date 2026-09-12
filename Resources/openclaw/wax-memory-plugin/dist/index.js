import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

const PLUGIN_ID = "wax-memory";
const DEFAULT_HTTP_ENDPOINT = "http://127.0.0.1:3000/mcp";
const EMPTY_PROMPT_LINES = Object.freeze([]);

function resolveSharedHttpEndpoint(pluginConfig) {
  const raw = pluginConfig?.endpoint;
  if (typeof raw === "string") {
    const trimmed = raw.trim();
    if (trimmed.length > 0) {
      return trimmed;
    }
  }
  return DEFAULT_HTTP_ENDPOINT;
}

function promptBuilder() {
  // Synchronous and side-effect free (AC-018). No I/O and no memory bodies.
  return EMPTY_PROMPT_LINES;
}

function flushPlanResolver() {
  // Host memory-flush plan only. Not a "run checkpoint now" callback.
  return null;
}

function registerExclusiveMemorySlot(api) {
  if (typeof api.registerMemoryCapability === "function") {
    api.registerMemoryCapability({
      promptBuilder,
      flushPlanResolver,
    });
    return;
  }
  if (typeof api.registerMemoryPromptSection === "function") {
    api.registerMemoryPromptSection(promptBuilder);
  }
  if (typeof api.registerMemoryFlushPlan === "function") {
    api.registerMemoryFlushPlan(flushPlanResolver);
  }
}

export default definePluginEntry({
  id: PLUGIN_ID,
  name: "Wax Memory",
  description:
    "Exclusive OpenClaw memory slot for the shared Wax MCP HTTP endpoint. Never spawns a second writer.",
  kind: "memory",
  register(api) {
    const endpoint = resolveSharedHttpEndpoint(api.pluginConfig);
    if (typeof api.logger?.debug === "function") {
      api.logger.debug(
        `wax-memory: shared HTTP endpoint ${endpoint}; no process fallback; preserve server embeddings`,
      );
    }
    registerExclusiveMemorySlot(api);
  },
});

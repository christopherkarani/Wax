# Wax Memory Plugin For OpenClaw

Exclusive OpenClaw memory slot (`plugins.slots.memory` = `wax-memory`) that
points at the **already running** shared Wax MCP HTTP endpoint. Chat dies; Wax
does not.

This plugin does **not** spawn `waxmcp` / `wax-mcp`. It does **not** pass
`--no-embedder`. Embeddings stay whatever the shared server was started with.

## Ownership: Level B

**Level B** (prime/slot only). Not Level A.

Evidence (pinned probe: `Tests/WaxMCPServerTests/Fixtures/hosts/openclaw/sdk-names.json`):

- The pinned SDK probe (`>=2026.3.24-beta.2`; public docs and published source,
  not a compile probe) marks `api.registerMemoryPromptPreparation` and the
  `registerMemoryCapability` fields `promptBuilder` / `flushPlanResolver` as
  documented. Current SDKs keep them; the split registrars
  (`registerMemoryPromptSection`, `registerMemoryFlushPlan`) are the deprecated
  path. This plugin feature-detects `registerMemoryCapability` first, then the
  older section and flush-plan registrars. It does **not** invent missing APIs.
- `registerMemoryPromptPreparation` is **not** wired. Loading Wax via `recall`
  would auto-open a transport session. Level A is the only ownership that may
  set `WAX_MCP_AUTO_SESSION=0`, and this plugin does not wrap every Wax
  read/write (agents still call MCP tools). Stay Level B; do not set that env.
- No documented terminal lifecycle callback with stable session identity is
  proven: `flushPlanResolver` returns a plan, not a close, and runtime
  lifecycle hooks are plugin-resource cleanup. Terminal checkpoint is skipped.
  Transport sessions end through Wax lease expiry.

`promptBuilder` (or `registerMemoryPromptSection`) returns frozen empty lines:
synchronous, no I/O, no memory bodies (AC-018). `flushPlanResolver` /
`registerMemoryFlushPlan` returns `null` (a plan, not a checkpoint).

## Recommended Wax Runtime

One shared HTTP writer. Preserve that process's embedder:

```bash
npx -y waxmcp@latest install
~/.local/share/waxmcp/bin/start-wax-mcp-http.sh
# if LaunchAgent ai.wax.mcp-http is loaded:
# launchctl kickstart -k "gui/$(id -u)/ai.wax.mcp-http"
npx -y waxmcp@latest vector-health
```

Default endpoint: `http://127.0.0.1:3000/mcp`.

Do **not** start a second server on that port. Do **not** use
`waxmcp mcp serve --no-embedder --transport http --http-port 3000` as a plugin
fallback. A second writer locks the store and silently disables vectors.

Also point OpenClaw's MCP client at the **same** URL (the plugin occupies the
memory slot; it is not a second MCP server).

## Install In OpenClaw

```bash
openclaw plugins install @wax/openclaw-wax-memory
# or, from a checkout:
openclaw plugins install /absolute/path/to/Resources/openclaw/wax-memory-plugin
```

```json
{
  "plugins": {
    "entries": {
      "wax-memory": {
        "enabled": true,
        "config": {
          "endpoint": "http://127.0.0.1:3000/mcp"
        }
      }
    },
    "slots": {
      "memory": "wax-memory"
    }
  }
}
```

Restart the OpenClaw gateway after changing plugin config.

Plugin metadata accepts only `endpoint`. There is no process fallback to
configure; the plugin never launches a Wax process.

Paste the SOUL.md stanza from
`Resources/skills/public/wax-mcp/references/project-rules.md` into workspace
`SOUL.md` (replace an existing `## Memory (Wax)` section).

## src → dist

`src/index.ts` is publishable ESM (no TypeScript-only syntax). `dist/index.js`
is a byte copy used as `openclaw.extensions`. Canonical
`Resources/openclaw/wax-memory-plugin` and
`Resources/npm/waxmcp/plugins/openclaw` stay lockstep.

Parent / CI:

```bash
diff -q Resources/openclaw/wax-memory-plugin/src/index.ts \
        Resources/openclaw/wax-memory-plugin/dist/index.js
diff -q Resources/openclaw/wax-memory-plugin/src/index.ts \
        Resources/npm/waxmcp/plugins/openclaw/src/index.ts
diff -q Resources/openclaw/wax-memory-plugin/dist/index.js \
        Resources/npm/waxmcp/plugins/openclaw/dist/index.js
```

`scripts/verify-openclaw-adapter.sh` runs that lockstep check (and forbids the
removed spawn fallback) before its existing Swift filters.

Optional typed compile against a newer SDK that actually exports the names
(not required to ship this tree):

```bash
cd Resources/openclaw/wax-memory-plugin
npm install --save-dev openclaw@2026.8.1
npx tsc --target es2022 --module nodenext --moduleResolution nodenext \
  --checkJs --noEmit src/index.ts
# If you add TypeScript-only syntax later, emit dist with the same tsc flags
# plus --outDir dist, then copy the result to both plugin trees.
```

The peer remains `openclaw >=2026.3.24-beta.2` (Swift package test pins that
string). Do not import `registerMemoryPromptPreparation` from
`openclaw/plugin-sdk/memory-core`; that export is absent on the peer floor.

## Publish

If you are not publishing under the `@wax` scope, change the package name and
`openclaw.install.npmSpec` in `package.json` first.

```bash
cd Resources/openclaw/wax-memory-plugin
npm pack --dry-run
npm publish --access public
```

## Files

- `openclaw.plugin.json` — native plugin metadata (`id` `wax-memory`, `kind` `memory`).
- `package.json` — publishable package; peer `openclaw >=2026.3.24-beta.2`.
- `src/index.ts` — exclusive-slot registration; shared HTTP endpoint only.
- `dist/index.js` — byte copy of `src/index.ts` loaded by OpenClaw.

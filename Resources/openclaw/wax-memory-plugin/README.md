# Wax Memory Plugin For OpenClaw

This directory packages the Wax/OpenClaw integration contract that reached `9/10` readiness in the Wax repo:

- native memory-oriented plugin metadata
- a native plugin entry around `registerMemoryCapability`
- a deployment contract that points OpenClaw at the verified `wax-mcp` tool surface
- managed Markdown round-trips via `markdown_export` / `markdown_sync`

The package is structured to be publishable as a native OpenClaw plugin.

## What Is Verified Here

The Wax side is implemented and tested:

- broker-managed OpenClaw memory tools
- `MEMORY.md` / daily note / `DREAMS.md` export
- `markdown_sync` import + reconcile
- `DREAMS.md` approval flow for durable promotion
- HTTP MCP transport for remote deployments

What still needs to happen in a consuming OpenClaw deployment is installing the
plugin package, installing a Wax MCP runtime, selecting this plugin in
`plugins.slots.memory`, and pointing it at a running Wax MCP endpoint.

## Recommended Wax Runtime

This plugin does not bundle the Wax runtime. Install and verify `wax-mcp` first:

```bash
npx -y waxmcp@latest mcp doctor
```

Run Wax as a long-lived local HTTP MCP service:

```bash
wax-mcp --no-embedder --transport http --http-host 127.0.0.1 --http-port 3000 --http-endpoint /mcp
```

Keep HTTP bound to `127.0.0.1` unless an authenticated gateway provides rate
limits, TLS, and network access controls. Wax's built-in HTTP transport also
supports `--http-auth-token` / `WAX_MCP_HTTP_AUTH_TOKEN` and
`--http-max-body-bytes` / `WAX_MCP_HTTP_MAX_BODY_BYTES`; only enable the bearer
token when the OpenClaw host or gateway sends `Authorization: Bearer <token>`.

Or use stdio when OpenClaw is colocated with the Wax process:

```bash
wax-mcp --no-embedder
```

## Publish

If you are not publishing under the `@wax` scope, change the package name and `openclaw.install.npmSpec` in `package.json` first.

Validate the archive:

```bash
cd Resources/openclaw/wax-memory-plugin
npm pack --dry-run
```

Verify the Wax native-memory contract from the repo root:

```bash
scripts/verify-openclaw-native-memory.sh /tmp/wax-openclaw-native.json
```

Publish to npm:

```bash
cd Resources/openclaw/wax-memory-plugin
npm publish --access public
```

## Install In OpenClaw

Install the plugin from npm after the Wax runtime is available:

```bash
openclaw plugins install @wax/openclaw-wax-memory
```

Or install from a local checkout while iterating:

```bash
openclaw plugins install /absolute/path/to/Resources/openclaw/wax-memory-plugin
```

Select it as the memory plugin in `openclaw.json`:

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

## Runtime Verification

Before debugging OpenClaw host behavior, verify these in order:

1. `npx -y waxmcp@latest mcp doctor` reports a usable Wax runtime.
2. `wax-mcp --no-embedder --transport http --http-host 127.0.0.1 --http-port 3000 --http-endpoint /mcp` starts and stays running.
3. `scripts/verify-openclaw-native-memory.sh /tmp/wax-openclaw-native.json` passes from a Wax checkout.
4. `npm pack --dry-run` passes in this plugin directory.

If OpenClaw launches the process directly, ensure `command` resolves on the
OpenClaw host `PATH`, or configure an absolute path to the staged `wax-mcp`
binary.

## Files

- `openclaw.plugin.json`
  Native plugin metadata and config schema.
- `package.json`
  Publishable native OpenClaw package metadata.
- `src/index.ts`
  Entry showing the `registerMemoryCapability` hook.

## OpenClaw Notes

The current OpenClaw plugin SDK docs indicate:

- `registerMemoryCapability` is the preferred exclusive memory-plugin API.
- memory plugins may expose `publicArtifacts.listArtifacts(...)` for exported surfaces.
- ACP-backed harness sessions can consume the same Wax MCP endpoint through OpenClaw’s ACP bridge or direct MCP client mode.

This scaffold is intentionally narrow: it avoids inventing OpenClaw host behavior that should live in OpenClaw itself, while still giving the host a concrete integration point.

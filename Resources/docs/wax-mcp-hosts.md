# Connect a coding agent to Wax

This is the install path. The playbook already exists — do not add a fourth copy.

| Layer | Path | Job |
|---|---|---|
| MCP `instructions` | shipped by `wax-mcp` | Session lifecycle on every connect |
| Operator skill | `Resources/skills/public/wax-mcp` | Install + pointer; follow server `instructions` |
| Paste block | `Resources/skills/public/wax-mcp/references/project-rules.md` | AGENTS.md / CLAUDE.md / Cursor, plus a SOUL.md stanza for OpenClaw |

`wax-mcp` is the **operator** skill (using memory tools). `wax` is the **Swift framework** skill. Do not mix them.

## One store, one writer

All hosts on a machine must share `~/.wax/memory.wax`.

- **One client (Claude only):** stdio is fine.
- **Two or more clients (Claude + Cursor + Codex + Hermes):** run **one** HTTP server and point every host at it. A second `wax-mcp` / `wax-cli daemon` on the same store will lock or time out.

```bash
# Stage binaries + skill once (does not register any host)
npx -y waxmcp@latest install
```

`waxmcp install` stages the MiniLM runtime, the operator skill, a copy of
the Hermes provider, a checksum manifest, and
`~/.local/share/waxmcp/bin/start-wax-mcp-http.sh`. It does **not** write a
LaunchAgent. Custom `--store-path` isolates session files next to the store
unless `--session-root` or `WAX_SESSION_ROOT` / `WAX_SESSION_ROOT_DIR` is
set.

Keep **one** HTTP writer. Prefer the staged launcher:

```bash
~/.local/share/waxmcp/bin/start-wax-mcp-http.sh
```

If HTTP already runs as a login service, the label is `ai.wax.mcp-http`.
After install or upgrade, restart it — do not start a second process on
the same store (`npx waxmcp --transport http` and provider `auto_start`
included):

```bash
launchctl kickstart -k "gui/$(id -u)/ai.wax.mcp-http"
launchctl print "gui/$(id -u)/ai.wax.mcp-http"
```

The program path must be `~/.local/share/waxmcp/bin/start-wax-mcp-http.sh`.

To create the LaunchAgent the first time, write
`~/Library/LaunchAgents/ai.wax.mcp-http.plist` (absolute paths, `RunAtLoad`
and `KeepAlive`, logs under `~/.local/share/waxmcp/logs/`,
`WAX_BROKER_START_TIMEOUT_SECS=60`) and bootstrap it:

```bash
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/ai.wax.mcp-http.plist
launchctl kickstart -k "gui/$(id -u)/ai.wax.mcp-http"
```

Then prove vectors against that service:

```bash
npx -y waxmcp@latest vector-health
npx -y waxmcp@latest doctor
```

`vector-health` is green only when both `vectorSearchEnabled` and
`queryEmbeddingAvailable` are true (MiniLM identified). The check opens a
temporary MCP session, calls `stats`, and DELETE-closes it. Degraded output
prints the same install + launcher recovery path. `doctor` smoke-checks
the daily tool surface (it is host-name agnostic).

Stage the skill from the npm package or a checkout:

```bash
# After `npx waxmcp install` (preferred)
ls ~/.local/share/waxmcp/skills/wax-mcp

# From a Wax checkout
cp -a Resources/skills/public/wax-mcp ~/.local/share/waxmcp/skills/wax-mcp
```

Verify the server before wiring hosts:

```bash
curl -sS -X POST http://127.0.0.1:3000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"wax-host-check","version":"0"}}}'
```

Expect `serverInfo.name = wax-mcp`. Then pick a host below. Restart that host after editing its config.

---

## Claude Code

`wax-cli mcp install` is the Claude registrar. The npm launcher (`waxmcp.js`) serves MCP; it does **not** implement `mcp install --scope`.

From a checkout:

```bash
swift run --traits MCPServer wax-cli mcp install --scope user
```

That command:

1. Stages `wax-mcp` into a stable path
2. Runs `claude mcp add wax` (stdio against the staged binary)
3. Stages `~/.local/share/waxmcp/skills/wax-mcp`
4. Best-effort `claude install-skill` of that staged skill

If you already run the shared HTTP server, skip stdio and add the URL instead:

```bash
claude mcp remove -s user wax || true
claude mcp add wax -t http -s user -- http://127.0.0.1:3000/mcp
claude install-skill ~/.local/share/waxmcp/skills/wax-mcp
```

Confirm: `claude mcp get wax` and a new Claude session that can see `session_open`.

---

## Codex

Codex reads `~/.codex/config.toml`. Add an HTTP server (stdio against a store another process already holds will fail):

```toml
[mcp_servers.wax]
url = "http://127.0.0.1:3000/mcp"
```

Land the operator skill where Codex loads user skills:

```bash
cp -a ~/.local/share/waxmcp/skills/wax-mcp ~/.codex/skills/wax-mcp
```

If the host still ignores skills, paste `references/project-rules.md` into the **project** `AGENTS.md` — not into `~/.codex/AGENTS.md`. The user-global file is behavior-only.

Restart Codex. Confirm `session_open` is in the tool list.

---

## Cursor

User MCP file: `~/.cursor/mcp.json`

```json
{
  "mcpServers": {
    "wax": {
      "url": "http://127.0.0.1:3000/mcp"
    }
  }
}
```

Cursor does not load the Wax skill automatically. Either:

- paste `references/project-rules.md` into the project `AGENTS.md`, or
- add a project rule at `.cursor/rules/wax-mcp.mdc` whose body is that same paste block.

Do not commit a second playbook. Point at or paste the canonical block.

Restart Cursor. Confirm the `wax` MCP server is enabled in Settings → MCP.

---

## Hermes

Use **exactly one** Wax surface: the native memory provider. Hermes selects
it with `memory.provider`. That is the whole wire-up.

```bash
npx -y waxmcp@latest install
npx -y waxmcp@latest install-hermes-plugin
# keep HTTP up: start-wax-mcp-http.sh or LaunchAgent ai.wax.mcp-http
npx -y waxmcp@latest vector-health
hermes config set memory.provider wax-memory
```

The loopback endpoint `http://127.0.0.1:3000/mcp` is the default. Optional
overrides: `WAX_MCP_HTTP_ENDPOINT`, `$HERMES_HOME/wax-memory.json`, or
`hermes config set wax_memory.endpoint …`. Prefer LaunchAgent `ai.wax.mcp-http`
over provider `auto_start` so a second process does not lock the store.

```yaml
memory:
  provider: wax-memory
```

Do **not** add `wax-memory` to `plugins.enabled`. Memory providers are not
generic plugins. Adding it there is the two-surface trap (PluginManager and
the memory loader both try to load it). Do **not** also register
`mcp_servers.wax`. Do **not** install the generic `wax-mcp` operator skill
in this mode. Do not add a second stdio `wax` server.

Native tools are `wax_remember`, `wax_recall`, and `wax_stats` (plus related
`wax_*`). Call them directly; do not send them through a generic MCP
deferral router. The provider owns session lifecycle from the host
conversation id — **do not pass or invent a Wax `session_id`.**

Recall:

- Omit `scope` for **project-default**: hard-filter to the resolved
  project/repo. Empty project recall is a miss, not “I have no memory.”
- Pass `scope=global` only when you intend the whole local store (person
  facts, standing preferences). Global disables the current-project rank
  boost. It is **not** an authorization boundary.
- If you supply both `project` and `repo`, both tags must match.

Only point Hermes at a store every connected agent is trusted to read.

After the plugin is installed from **this** tree:

```bash
npx -y waxmcp@latest vector-health
hermes wax-memory doctor
hermes plugins doctor wax-memory
```

`hermes wax-memory` registers `status`, `doctor`, and `config` only. Do not
invent other subcommands. Confirm a new Hermes session lists `wax_remember`,
`wax_recall`, and `wax_stats`.

If argparse rejects `wax-memory`, or Plugin Doctor reports
`hermes_wax_memory module not found`, the installed plugin is stale. Re-run
`npx -y waxmcp@latest install-hermes-plugin` from this package, then rerun
both doctors. Do not “fix” that by adding `wax-memory` to `plugins.enabled`.

---

## Generic / OpenCode / Windsurf / anything else

1. Run the shared HTTP server above.
2. Point the host’s MCP config at `http://127.0.0.1:3000/mcp` (HTTP) or, if this is the only client, stdio:

   ```text
   command: /Users/<you>/.local/share/waxmcp/runtime/darwin-arm64/wax-mcp
   args:    --store-path /Users/<you>/.wax/memory.wax --embedder minilm
   ```

3. Paste the AGENTS.md fence from `Resources/skills/public/wax-mcp/references/project-rules.md` into the project `AGENTS.md` or `CLAUDE.md`. OpenClaw: paste the SOUL.md fence into `SOUL.md` (append if missing; replace an existing `## Memory (Wax)` section). Native Hermes does not use that MCP paste.

That file is the whole always-on prompt. Do not invent a `PROMPT.md`.

---

## What the agent should do once connected

**Native Hermes** uses `wax_remember` / `wax_recall` / `wax_stats` with no
Wax UUID. Project-default vs `scope=global` is above.

**MCP hosts** (Claude, Codex, Cursor, OpenClaw, generic) follow the paste
block:

1. Call `session_open` (`project`, stable `agent_id`/`run_id`). Keep `session_id`. Do not call `handoff_latest` then `session_start` as the default open.
2. Before the first answer: `recall` with `session_id` and `mode: text` for this job, plus `scope: global` for facts about the person. Omitted scope is current-project; empty project recall is a miss. `scope=global` searches the whole local store and is not an authorization boundary.
3. Lasting writes: `remember` with top-level `session_id` and `memory_type` `lesson` / `user_preference` / `fact` / `decision` / `constraint`. Do not pass `scope: durable`. Write one-line corrections too.
4. This job only: `task_state` with `session_id` (plan lock, failed path, landmine, before spawn or stop).
5. Close with `session_close` (`session_id`, short `content`, `pending_tasks`) when the job ends. Do not end between turns of one host chat.

### Pitfalls that show up on a real store

- Prefer `mode: "text"` for recent facts, exact names, and identity. Hybrid/vector can rank old embedder-test frames first.
- `memory_get` IDs look like `durable:1695` or `episodic:<session-uuid>:0`. A bare frame number fails.
- Do not invent a `session_id`. Use the value from `session_open` / `session_start` / `session_resume`.
- Do not manage `--store-path` or `flush` in normal agent flows.
- If tools vanish after a burst of bad calls, check that HTTP `:3000` is still up before restarting the broker. The host MCP client can circuit-break while the server is healthy.

---

## Diagnose / recover

```bash
npx -y waxmcp@latest doctor
# same check:
# ~/.local/share/waxmcp/runtime/darwin-arm64/wax-cli mcp doctor

npx -y waxmcp@latest vector-health
```

Hermes (native provider installed from this tree):

```bash
hermes wax-memory doctor
hermes plugins doctor wax-memory
```

`vector-health` must print both vector flags true. If it is degraded:

1. `npx -y waxmcp@latest install`
2. Restart HTTP: `launchctl kickstart -k "gui/$(id -u)/ai.wax.mcp-http"` when that LaunchAgent is loaded; otherwise run `~/.local/share/waxmcp/bin/start-wax-mcp-http.sh`
3. Rerun `npx -y waxmcp@latest vector-health`

If Hermes doctors fail to register or import, reinstall the plugin with
`npx -y waxmcp@latest install-hermes-plugin`. Do not add `wax-memory` to
`plugins.enabled`.

## Smoke test (any host)

Ask the agent: “Load Wax, start a session, and tell me the latest handoff.”

Pass if it:

1. MCP hosts: calls `session_open` (not `handoff_latest` then `session_start` as the default open). Native Hermes: calls `wax_remember` / `wax_recall` with no Wax `session_id`.
2. Does not ask you to restate prior context that memory already contains
3. Can `stats` / `wax_stats` and reports vector search on (or honestly says it is off)

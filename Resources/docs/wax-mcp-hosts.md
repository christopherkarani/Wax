# Connect a coding agent to Wax

This is the install path. The playbook already exists — do not add a fourth copy.

| Layer | Path | Job |
|---|---|---|
| MCP `instructions` | shipped by `wax-mcp` | Session lifecycle on every connect |
| Operator skill | `Resources/skills/public/wax-mcp` | Full playbook + anti-patterns |
| Paste block | `Resources/skills/public/wax-mcp/references/project-rules.md` | AGENTS.md / CLAUDE.md / Cursor, plus a SOUL.md stanza for Hermes / OpenClaw |

`wax-mcp` is the **operator** skill (using memory tools). `wax` is the **Swift framework** skill. Do not mix them.

## One store, one writer

All hosts on a machine must share `~/.wax/memory.wax`.

- **One client (Claude only):** stdio is fine.
- **Two or more clients (Claude + Cursor + Codex + Hermes):** run **one** HTTP server and point every host at it. A second `wax-mcp` / `wax-cli daemon` on the same store will lock or time out.

```bash
# Stage binaries + skill once (does not register any host)
npx -y waxmcp@latest install

# Shared HTTP server (pin MiniLM if the store was built with MiniLM)
npx -y waxmcp@latest --transport http --http-host 127.0.0.1 --http-port 3000 --http-endpoint /mcp --embedder minilm
```

If you already staged a runtime, this is equivalent:

```bash
~/.local/share/waxmcp/bin/start-wax-mcp-http.sh
# or:
# $HOME/.local/share/waxmcp/runtime/darwin-arm64/wax-mcp \
#   --store-path "$HOME/.wax/memory.wax" \
#   --embedder minilm --transport http \
#   --http-host 127.0.0.1 --http-port 3000 --http-endpoint /mcp
# Custom --store-path isolates session files next to the store unless
# --session-root or WAX_SESSION_ROOT / WAX_SESSION_ROOT_DIR is set.
```

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

Hermes wants **both** the native memory provider and the MCP tool surface, both pointed at the same HTTP endpoint.

```bash
npx -y waxmcp@latest install-hermes-plugin

hermes config set memory.provider wax-memory
hermes config set wax_memory.endpoint http://127.0.0.1:3000/mcp --force
hermes config set wax_memory.auto_start true --force
```

Register MCP (non-interactive). `hermes mcp add` is TTY-only — write `mcp_servers.wax` in `~/.hermes/config.yaml`:

```yaml
memory:
  provider: wax-memory

wax_memory:
  endpoint: http://127.0.0.1:3000/mcp
  auto_start: true

mcp_servers:
  wax:
    url: http://127.0.0.1:3000/mcp
    enabled: true
    timeout: 180
    connect_timeout: 60
```

Install the operator skill, then append the SOUL.md fence from `references/project-rules.md` to `~/.hermes/SOUL.md` (or `$HERMES_HOME/SOUL.md`). Do not replace the rest of the soul.

```bash
cp -a ~/.local/share/waxmcp/skills/wax-mcp ~/.hermes/skills/mcp/wax-mcp
```

Start a **new** Hermes session (MCP reload is required). Confirm `hermes mcp test wax` and that `handoff_latest` / `recall` are visible.

Do not add a second stdio `wax` server. Do not put `wax-memory` in `plugins.enabled` — the exclusive backend is `memory.provider: wax-memory`.

---

## Generic / OpenCode / Windsurf / anything else

1. Run the shared HTTP server above.
2. Point the host’s MCP config at `http://127.0.0.1:3000/mcp` (HTTP) or, if this is the only client, stdio:

   ```text
   command: /Users/<you>/.local/share/waxmcp/runtime/darwin-arm64/wax-mcp
   args:    --store-path /Users/<you>/.wax/memory.wax --embedder minilm
   ```

3. Paste the AGENTS.md fence from `Resources/skills/public/wax-mcp/references/project-rules.md` into the project `AGENTS.md` or `CLAUDE.md`. Hermes / OpenClaw: append the SOUL.md fence to `SOUL.md` instead of replacing the soul.

That file is the whole always-on prompt. Do not invent a `PROMPT.md`.

---

## What the agent should do once connected

Same rules on every host (from the paste block):

1. Call `session_open` (`project`, stable `agent_id`/`run_id`, optional `recall_query`). Keep `session_id`. Do not call `handoff_latest` then `session_start` as the default open.
2. Tactical writes: `remember` **with** `session_id` or `scope: session` (`task_state` / `working`) when a plan locks, a path fails, or you are about to stop
3. Strategic writes: `remember` with `scope: durable` (or without `session_id`) for decision / lesson / constraint / preference / fact
4. `recall` defaults to `scope: project` (hard-filters; empty lane is an explicit miss). Pass `scope: global` only for cross-project reads. With `session_id`, recall merges that session with durable under project scope. Prefer `mode: "text"` for exact names.
5. Close with `session_close` (or `handoff` then `session_end`). Do not end between turns of one host chat.

### Pitfalls that show up on a real store

- Prefer `mode: "text"` for recent facts, exact names, and identity. Hybrid/vector can rank old embedder-test frames first.
- `memory_get` IDs look like `durable:1695` or `episodic:<session-uuid>:0`. A bare frame number fails.
- Do not invent a `session_id`. Use the value from `session_open` / `session_start` / `session_resume`.
- Do not manage `--store-path` or `flush` in normal agent flows.
- If tools vanish after a burst of bad calls, check that HTTP `:3000` is still up before restarting the broker. The host MCP client can circuit-break while the server is healthy.

---

## Smoke test (any host)

Ask the agent: “Load Wax, start a session, and tell me the latest handoff.”

Pass if it:

1. Calls `session_open` (not `handoff_latest` then `session_start` as the default open)
2. Does not ask you to restate prior context that the handoff already contains
3. Can `stats` and reports vector search on (or honestly says it is off)

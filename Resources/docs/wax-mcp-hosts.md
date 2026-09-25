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
- **Two or more clients (Claude + Cursor + Codex + Hermes):** run **one** HTTP server and point every host at it. Identical stdio servers attach to one broker daemon automatically; a differently-configured second `wax-mcp` / `wax-cli daemon` on the same store fails fast with sharing guidance instead of hanging.

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

`wax-cli mcp install` is the host registrar. The npm launcher (`waxmcp.js`) serves MCP; it does **not** implement `mcp install --scope`.

From a checkout:

```bash
swift run --traits MCPServer wax-cli mcp install --scope user
```

That command registers every detected host (Claude Code, Muse Code, Cursor, Codex, Grok, OpenCode — see `--hosts auto|all|claude,muse,cursor,codex,grok,opencode`), skipping what it cannot find with a printed reason:

1. Stages `wax-mcp` into a stable path
2. Runs `claude mcp add wax` (stdio against the staged binary)
3. Merges the same stdio entry into Muse settings, Cursor `mcp.json`, and OpenCode `opencode.json`; prints the Codex/Grok TOML snippet (writes it with `--write-toml-config`)
4. Stages `~/.local/share/waxmcp/skills/wax-mcp`
5. Best-effort skill install per host (`claude install-skill`, `muse skills install`, Codex skill copy)

If you already run the shared HTTP server, skip stdio and add the URL instead:

```bash
claude mcp remove -s user wax || true
claude mcp add wax -t http -s user -- http://127.0.0.1:3000/mcp
claude install-skill ~/.local/share/waxmcp/skills/wax-mcp
```

Confirm: `claude mcp get wax` and a new Claude session that can see `remember`,
`recall`, and `stats` (the daily `tools/list`).

---

## Codex

Automatic setup: `wax-cli mcp install` prints the exact stdio block for `~/.codex/config.toml` (or appends it with `--write-toml-config`, failing closed if an existing block differs) and copies the skill to `~/.codex/skills/wax-mcp`.

Manual setup: Codex reads `~/.codex/config.toml`. Add an HTTP server (stdio against a store another process already holds will fail):

```toml
[mcp_servers.wax]
url = "http://127.0.0.1:3000/mcp"
```

Land the operator skill where Codex loads user skills:

```bash
cp -a ~/.local/share/waxmcp/skills/wax-mcp ~/.codex/skills/wax-mcp
```

If the host still ignores skills, paste `references/project-rules.md` into the **project** `AGENTS.md` — not into `~/.codex/AGENTS.md`. The user-global file is behavior-only.

Restart Codex. Confirm `remember`, `recall`, and `stats` are in the tool list.

---

## Cursor

Automatic setup: `wax-cli mcp install` merges a stdio entry into the user MCP file below.

Manual setup. User MCP file: `~/.cursor/mcp.json`

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

- Omit `mode` unless you need an override. Hybrid is the default.
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

## Grok CLI

Automatic setup: `wax-cli mcp install --hosts grok` prints the exact stdio block for `~/.grok/config.toml` (`$GROK_HOME/config.toml` when set), or appends it with `--write-toml-config`, failing closed if an existing block differs.

Daily install is the shared HTTP server plus a Grok MCP entry. Do **not** use
`GROK_CONFIG` / `GROK_CONFIG_PATH` to retarget Wax — those overlays cannot
change `mcp_servers` (network redirect is dropped on purpose).

```bash
grok mcp add --transport http wax http://127.0.0.1:3000/mcp
```

With the default daily tool set the server auto-opens a transport-scoped
session; there is no `session_open` to call. Under `WAX_MCP_TOOLS=legacy`, pass
`conversation_id` as the Grok session UUID on every `session_open` so
compaction resumes the same Wax session instead of minting a sibling. Grok
currently requires a `search_tool` schema lookup before each MCP call; that is
a host tax, not a Wax tool bug. Pin Wax tools in the host if the host supports
it. Budget about 3 points of residual on hosts that force schema lookup every
call. A 95 agent-DX score is a cohort average (Claude/Codex with pinned tools
can land higher); it is not a guarantee for every Grok session.

To point a throwaway agent at an isolated `wax-mcp` (unreleased binary, separate
store, not `~/.wax`), use a **project** config and a **private leader**. Shared
`~/.grok/leader.sock` keeps the live `:3000` watches.

```bash
# from the throwaway git repo you want inferred as project
mkdir -p .grok
cat > .grok/config.toml <<'EOF'
[mcp_servers.wax]
url = "http://127.0.0.1:3140/mcp"
enabled = true
EOF
grok --leader-socket /path/to/isolated.leader.sock --cwd "$PWD"
# or: grok --no-leader --cwd "$PWD"
# or: GROK_HOME=/path/to/throwaway-grok-home (its own config.toml)
```

`grok mcp add --scope project --transport http …` writes that project file.
Do not rewrite `~/.grok/config.toml` just to isolate a lab.

---

## Muse Code

Muse Code (Meta, powered by Muse Spark) reads
`~/.config/muse/settings.json` (`schema_version: 1`) and takes MCP servers
under `mcp_servers` (`mcpServers` is accepted as an alias). Each entry picks
`transport: "stdio"` (`command`/`args`/`env`) or
`transport: "streamable_http"` (`url`/`headers`), plus `mode: "required"` or
`"optional"`.

Automatic setup (recommended): `wax-cli mcp install` registers every
detected host, Muse included. Limit with `--hosts` (e.g. `--hosts muse`)
or exclude Muse with `--skip-muse`. It merges a stdio `mcp_servers.wax`
entry and installs the `wax-mcp` skill when the `muse` CLI is present.

Manual setup. Solo on this machine (Muse is the only client), stdio is
fine. The server command is `wax-cli mcp serve` (it execs the `wax-mcp`
binary) or the `wax-mcp` binary directly:

```json
{
  "schema_version": 1,
  "mcp_servers": {
    "wax": {
      "transport": "stdio",
      "command": "wax-cli",
      "args": ["mcp", "serve"],
      "mode": "optional"
    }
  }
}
```

Two or more clients must share **one** HTTP server on
`http://127.0.0.1:3000/mcp` — a differently-configured second writer on `~/.wax/memory.wax` fails fast; share the server instead:

```json
{
  "schema_version": 1,
  "mcp_servers": {
    "wax": {
      "transport": "streamable_http",
      "url": "http://127.0.0.1:3000/mcp",
      "mode": "optional"
    }
  }
}
```

Use `"optional"`: a `required` server that fails to start aborts the whole
Muse run, and a memory server must never do that.

Teach the model when to use Wax: paste the AGENTS.md fence from
`Resources/skills/public/wax-mcp/references/project-rules.md` into the
project `AGENTS.md`:

```text
Follow the live Wax MCP server instructions for `remember`, `recall`, and `stats`. Do not invent a `session_id`. Do not load the `wax` or `wax-mcp` skills at session start. `wax` is Swift SDK only; `wax-mcp` is install/doctor only.
```

Restart Muse. Smoke test: run `/mcp` in-session and confirm `wax` is
listed, then ask the agent to remember one fact, recall it, and run
`stats`.

---

## Generic / OpenCode / Windsurf / anything else

Automatic setup for OpenCode: `wax-cli mcp install --hosts opencode` merges a local stdio entry into `opencode.json` (`OPENCODE_CONFIG` / `OPENCODE_CONFIG_DIR` honored, else `~/.config/opencode/opencode.json`). JSONC configs (`.jsonc`, or a `.json` path with comments) are never edited — add the entry there manually.

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

**MCP hosts** follow the live server `instructions`. Default `tools/list` is
`remember`, `recall`, and `stats`. The server auto-opens one transport-scoped
session. This is **transport-owned** working memory, not per-chat isolation:

Ownership levels, least to most authority:

- **Level C** — transport-owned working memory. Sessions key off the MCP
  connection, not a proven host chat. A multiplexed connection can span more
  than one host chat.
- **Level B** — Level C plus read-only prime injection at session start
  (bounded, sanitized, marked as historical data) and/or host hook checkpoint.
- **Level A** — the host wraps every Wax read/write with a proven conversation
  identity and owns terminal close. Only Hermes ships this today.

- Claude Code, Codex, Grok, Cursor, Muse: Level C plus optional Level B prime.
- OpenCode: Level B only. There is no shipped Level A plugin that wraps
  every Wax read/write with the OpenCode session ID. Close is not available
  on `session.idle` or `session.compacted`.
- OpenClaw: Level B. The plugin talks to the shared HTTP endpoint only and
  does not spawn a writer. The pinned SDK does not expose a proven terminal
  lifecycle callback, so checkpoint relies on transport teardown / lease.
- Hermes: Level A through `memory.provider: wax-memory` only.

Ungraceful crash recovery uses the existing 300-second session lease and
7-day recently-closed reclaim window; SIGKILL does not checkpoint.

### Host hooks (optional, opt-in)

`wax-cli mcp wire-hooks` merges Wax-owned hook entries into host config files
(typed JSON merge, fail-closed on malformed configs, preimage-checked writes
with rollback, `.waxbak` backup). `waxmcp install --wire-hooks` runs it against
the default per-host paths after staging (`--dry-run` previews without
writing). Wired hooks call back into `wax-cli mcp run-hook`, which reads the
host's JSON stdin and never fails the host:

- `prime` (SessionStart: claude, codex, grok, muse) prints a bounded, sanitized
  context envelope for the host to inject. Prime is probe-only: it never opens
  a session, never starts a broker, and exits 0 with an explicitly-marked empty
  envelope when the broker is down (`status: probe_failed`, distinct from an
  empty store). `--with-prompt-prefetch` also wires a read-only prime hook on
  `UserPromptSubmit`. `wax-cli mcp prime` runs it standalone.
- `checkpoint` closes the exact session (`--session-id`) or the namespaced host
  conversation (`--host` + `--conversation-id`), never opens one, and skips
  cleanly when nothing is bound. `--strict` exits nonzero on skip. Stop, idle,
  and compaction events never close. `wire-hooks` does not install checkpoint
  hooks today (that is Level A ownership); transport teardown is the close path.

Cursor's `sessionStart` prime is **not** wired by the installer: the hook
format reserves a `requiresLiveInjectionProbe` marker for a future live
`additional_context` probe, and the entry stays off until that probe exists.

1. Follow the live MCP server instructions. Call `remember` and `recall` with `cwd` when roots are not advertised. Do not invent a `session_id`. Do not call `handoff_latest` then `session_start` as the default open.
2. `recall` is self-contained. Do not recall again on follow-ups unless the job changed. Omit `mode` unless you need an override. Empty project recall is a miss. `scope=global` searches the whole local store and is not an authorization boundary.
3. Lasting writes: `remember` with `memory_type` `lesson` / `user_preference` / `fact` / `decision` / `constraint`. A successful save has `status: ok` and `committed: true`. If `committed` is false or the call errors, the write did not land.
4. Do not close on Stop, idle, or compaction. Transport teardown checkpoints. `leftover_reasons` are harvest skips — ignore them. Set `WAX_MCP_TOOLS=legacy` to restore `session_open` / `session_close` / `memory_get` / `compact_context` / `session_resume`. In that profile, session_open with recall_query is enough. The connection remembers `session_id`; omit it after that. `WAX_MCP_AUTO_SESSION=0` restores explicit-open.

### Pitfalls that show up on a real store

- Omit `mode` unless you need an override. Hybrid ranking promotes distinctive tokens and recent lexical matches; exact identifiers still route to text. `mode: vector` throws without an embedder.
- Daily `recall` returns usable text. `memory_get` IDs (legacy/full) look like `durable:1695` or `episodic:<session-uuid>:0`. A bare frame number fails.
- Do not invent a `session_id`.
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

Ask the agent: “Load Wax, remember one fact, recall it, and run stats.”

Pass if it:

1. MCP hosts: calls `remember` / `recall` / `stats` (not `handoff_latest` then `session_start` as the default open). Native Hermes: calls `wax_remember` / `wax_recall` with no Wax `session_id`.
2. Does not ask you to restate prior context that memory already contains
3. Can `stats` / `wax_stats` and reports vector search on (or honestly says it is off)

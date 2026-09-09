<!-- HEADER:START -->

<div align="center">
  <a href="https://trendshift.io/repositories/21759?utm_source=trendshift-badge&amp;utm_medium=badge&amp;utm_campaign=badge-trendshift-21759" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/trendshift/repositories/21759/daily?language=Swift" alt="christopherkarani%2FWax | Trendshift" width="250" height="55"/></a>
  <img src="Resources/docs/assets/wax-banner.png" width="800" alt="Wax — local-first shared memory for AI agents">
</div>

<div style="height: 16px;"></div>

<p align="center">
  <strong>Chat dies. Wax does not.</strong><br/>
  One local <code>.wax</code> file for Claude, Codex, Hermes, Cursor, and Apple Foundation Models.<br/>
  Searchable memory on disk. No account. No hosted vector DB.
</p>

<p align="center">
  <a href="https://www.npmjs.com/package/waxmcp"><img src="https://img.shields.io/npm/v/waxmcp?style=flat-square&logo=npm&label=waxmcp" alt="npm waxmcp" /></a>
  <a href="https://github.com/christopherkarani/Wax/releases"><img src="https://img.shields.io/github/v/release/christopherkarani/Wax?style=flat-square&logo=swift&logoColor=white&label=Swift" alt="Swift" /></a>
  <a href="https://developer.apple.com/"><img src="https://img.shields.io/badge/platform-macOS%20%7C%20iOS%20%7C%20Linux-lightgrey?style=flat-square" alt="Platforms" /></a>
  <a href="https://github.com/christopherkarani/Wax/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-blue?style=flat-square" alt="License" /></a>
  <a href="https://github.com/christopherkarani/Wax/stargazers"><img src="https://img.shields.io/github/stars/christopherkarani/Wax?style=flat-square&logo=github" alt="Stars" /></a>
  <a href="https://discord.gg/NHgNh7HJ6M"><img src="https://img.shields.io/badge/Discord-join-5865F2?style=flat-square&logo=discord&logoColor=white" alt="Discord" /></a>
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="Resources/locales/README.es.md">Español</a> · <a href="Resources/locales/README.fr.md">Français</a> · <a href="Resources/locales/README.ja.md">日本語</a> · <a href="Resources/locales/README.ko.md">한국어</a> · <a href="Resources/locales/README.pt.md">Português</a> · <a href="Resources/locales/README.zh-CN.md">中文</a>
</p>
<!-- HEADER:END -->

```bash
npx -y waxmcp@latest install
```

That stages the MCP server, MiniLM runtime, and operator skill on Apple Silicon. Wire one host, paste the [playbook](#2-teach-the-model-when-to-use-wax), and the next session can `remember` / `recall`. If this is the memory layer you wanted, [star the repo](https://github.com/christopherkarani/Wax) so other agents find it.

<p align="center">
  <img src="Resources/docs/assets/demo-terminal.svg" width="720" alt="Wax CLI Demo">
</p>

---

## What Wax is

Wax is a **shared memory file** for agents and on-device models.

```text
Claude Code ─┐
Codex ───────┤
Cursor ──────┼─ MCP ─→  one HTTP writer  ─→  ~/.wax/memory.wax
Grok ────────┤
OpenClaw ────┘
Hermes ──────── native wax-memory provider ─↗
iPhone / Mac app ── Memory + Foundation Models tools ─↗
```

The store is one file. Documents, FTS5 text search, CoreML vectors, and a WAL live inside it. iCloud or AirDrop the file to another Mac or iPhone. A second MCP process on the same path will lock, so two or more hosts share `http://127.0.0.1:3000/mcp`.

**What you get that a host scratchpad does not:**

- Claude, Codex, Cursor, and Hermes read and write the **same** memories.
- `remember` does not call an LLM to extract facts. You store a sentence; hybrid search finds it later.
- Apple Foundation Models get `waxRemember` / `waxRecall` / `waxSearch` as on-device tools.
- Hermes can drop `MEMORY.md` curation and use the native `wax-memory` provider (handoffs, turn sync, `wax_remember` / `wax_recall`).

Host playbook: [wax-mcp-hosts.md](Resources/docs/wax-mcp-hosts.md)

---

## Agent Quick Start

Give Claude Code, Cursor, Codex, Hermes, OpenClaw, or Windsurf a memory that survives the chat.

Installing the server is not enough. Hosts ignore MCP tool descriptions unless an always-on file says **when** to write. Paste a block below after you wire the host.

### 1. Stage the server once

```bash
npx -y waxmcp@latest install
```

**Claude-only** can use stdio. **Two or more clients must share one HTTP server** on `http://127.0.0.1:3000/mcp`. A second process on `~/.wax/memory.wax` will lock.

<details>
<summary><strong>Host wire-up (Claude, Codex, Cursor, Hermes, OpenClaw)</strong></summary>

| Host | Wire-up |
|------|---------|
| Claude Code | `swift run --traits MCPServer wax-cli mcp install --scope user` then `claude install-skill ~/.local/share/waxmcp/skills/wax-mcp` |
| Codex | `[mcp_servers.wax] url = "http://127.0.0.1:3000/mcp"` in `~/.codex/config.toml` + copy the skill to `~/.codex/skills/wax-mcp` |
| Cursor | `{ "mcpServers": { "wax": { "url": "http://127.0.0.1:3000/mcp" } } }` in `~/.cursor/mcp.json` + paste the AGENTS.md block |
| Hermes | Native `memory.provider: wax-memory` only. `npx -y waxmcp@latest install-hermes-plugin`, then `hermes config set memory.provider wax-memory`. Daily tools: `wax_remember` / `wax_recall` (no Wax UUID). Do not add `wax-memory` to `plugins.enabled`. Do not also register `mcp_servers.wax`. |
| OpenClaw | HTTP + memory plugin + paste the SOUL.md stanza into the workspace `SOUL.md`; replace an existing `## Memory (Wax)` section |
| Anything else | HTTP URL + paste the AGENTS.md block into project `AGENTS.md` |

Keep HTTP up with `~/.local/share/waxmcp/bin/start-wax-mcp-http.sh` or LaunchAgent `ai.wax.mcp-http`. Prove it with `npx -y waxmcp@latest vector-health`, `npx -y waxmcp@latest doctor` (`wax-cli mcp doctor`), `hermes wax-memory doctor`, and `hermes plugins doctor wax-memory`. Native recall defaults to the current project; pass `scope=global` for person facts. Global is not an authorization boundary.

Full snippets, LaunchAgent `ai.wax.mcp-http`, `vector-health`, Hermes doctors, and a smoke test: [Resources/docs/wax-mcp-hosts.md](Resources/docs/wax-mcp-hosts.md).

The **wax-mcp** skill is the operator playbook. The **wax** skill is Swift framework integration. Different audience.

</details>

### 2. Teach the model when to use Wax

Pick the file your host actually loads on every turn.

<details>
<summary><strong>Paste into AGENTS.md / CLAUDE.md / Cursor rules</strong></summary>

Use the project or user `AGENTS.md`, `CLAUDE.md`, or `.cursor/rules`. Same text as `Resources/skills/public/wax-mcp/references/project-rules.md`.

```text
Wax is shared memory. Chat dies; Wax does not.

Learn. Write the moment it would change the next agent's behavior — including a one-line correction or preference:
- user_preference — how this person works, who they are, standing corrections
- lesson — we got burned; do not do that again
- fact — a true thing about this repo or product the next agent needs
- decision / constraint — a choice that should bind later work

Skip only empty chit-chat. Store one or two sentences. Do not store chats, test logs, plan drafts, or secrets.

Open: call `session_open` (`project` = repo, stable `agent_id` / `run_id`, `conversation_id` = this host chat id when the host has one). The MCP connection remembers `session_id`; omit it on subsequent `remember`, `recall`, `compact_context`, and `session_close` calls on this connection. Keep the returned ID for `session_resume` after reconnecting or for explicitly selecting another session. Do not invent one. Same `agent_id`+`run_id` resumes. Same `conversation_id` resumes the unique live match. Same `agent_id`+project rebinds if exactly one live session exists. If more than one is live, open a new session — do not guess.

Before the first answer:
1. `recall` with `mode: text`, query = this job
2. `recall` with `scope: global`, `mode: text`, `memory_types: ["user_preference"]`, query = facts about this person / standing corrections
Empty project recall is a miss, not "I have no memory."

Lasting writes: `remember` with `memory_type` `lesson` | `user_preference` | `fact` | `decision` | `constraint`. Do not pass `scope: durable`. Type keeps them durable and stamps the project so default recall can find them. Person-facts use the connection session; read them later with `scope: global` plus `memory_types`. Never put `session_id` in `metadata`.

This job only (not the default write): `remember` with `memory_type: task_state`, `durability: working` — plan lock, failed path, landmine, before you spawn or stop. Parent writes before spawning; children often have no Wax tools.

Close when the job ends, not between turns or after compaction: `session_close` with a short state `content`, and `pending_tasks` for unfinished work. Compaction is not job end. If omit-id fails after reconnect, pass the saved UUID or call `session_open` with the same `conversation_id`. If a call returns inactive / `resumable: false`, call `session_open` again. Follow the MCP server instructions when present.
```

</details>

<details>
<summary><strong>Paste into Hermes / OpenClaw SOUL.md</strong></summary>

OpenClaw: the workspace `SOUL.md`. Native Hermes (`memory.provider: wax-memory`)
already owns session lifecycle — do not paste the MCP `session_open` loop
below into Hermes. Call `wax_remember` / `wax_recall` instead.

SOUL.md is identity. **Append** this section if missing. If `## Memory (Wax)` already exists, **replace that section**. Do not replace the rest of the soul.

```text
## Memory (Wax)

You have Wax. Chat is not memory. Learn this person and keep it.

Write the moment it would change how you treat them or the work — including a one-line correction:
- user_preference — how they work, who they are, standing corrections
- lesson — we got burned
- fact — something true that should stick
- decision / constraint — a choice that should bind later work

Store one or two sentences. Do not store chats, status, or secrets.

On every real job: call `session_open` (`project` = the repo you are in, `agent_id` = your name, `run_id` = this conversation, `conversation_id` = this host chat id). The MCP connection remembers `session_id`; omit it on subsequent `remember`, `recall`, `compact_context`, and `session_close` calls on this connection. Keep the returned ID for `session_resume` after reconnecting or for explicitly selecting another session. Do not invent one. Do not open per message. Do not close between turns or after compaction.

Before you act:
1. `recall` with `mode: text`, query = this repo/job
2. `recall` with `scope: global`, `mode: text`, `memory_types: ["user_preference"]`, query = facts about this person

Lasting writes: `remember` with `memory_type` `user_preference` | `lesson` | `fact` | `decision` | `constraint`. Do not pass `scope: durable`.

This job only: `remember` with `memory_type: task_state`, `durability: working`.

Close with `session_close` (short `content`, `pending_tasks`) when the job ends. Compaction is not job end. If omit-id fails after reconnect, pass the saved UUID or call `session_open` with the same `conversation_id`. If a call returns inactive / `resumable: false`, call `session_open` again. Follow the MCP server instructions when present.
```

Native Hermes (`memory.provider: wax-memory`) does **not** use that MCP paste
as its tool surface. Call `wax_remember` / `wax_recall` / `wax_stats`. Do not
pass a Wax `session_id`. Omit `scope` for current-project recall; pass
`scope=global` for person facts. Empty project recall is a miss. Do not add
`wax-memory` to `plugins.enabled`. OpenClaw still pastes the SOUL.md stanza.

</details>

<details>
<summary><strong>Grokbot (xAI) — paste this into your Bot after wiring the server</strong></summary>

Grokbot runs locally on your Mac, so Wax serves it over loopback. No tunnel. No cloud copy of your memory.

One-time setup:

```bash
# 1. Stage Wax
npx -y waxmcp@latest install

# 2. Start the server and keep it running (add to your shell profile / login items)
~/.local/share/waxmcp/bin/start-wax-mcp-http.sh
```

Then in Grokbot: **Settings → Plugins → Add MCP server**

| Field | Value |
|-------|-------|
| Name | `wax` |
| URL | `http://127.0.0.1:3000/mcp` |

Finally, paste this prompt into your **main (coordinator) bot**. It sets up its own memory and rolls Wax out to every bot on the team:

```text
You have a memory tool server called "wax". Use it as your primary memory, and make it the primary memory for every bot on our team.

Your own memory:
- Starting any multi-step job: call session_open (project set to my name, stable agent_id/run_id), keep the returned session_id, then recall with mode text before you act. Also recall scope global for facts about me.
- While working: write lessons, user_preference, and facts with session_id the moment they show up (including a one-line correction). Do not pass scope durable. task_state is only for this job (plan, failed path, landmine).
- Finishing: session_close with a short summary and pending_tasks so your next session resumes cleanly.
- Never store passwords, tokens, or secrets. If the wax tools are missing, stop and tell me instead of improvising.

Roll out to the team:
1. List every bot we already have. For each one, add the "Your own memory" rules above to its persistent instructions/memory, then verify it can see the wax tools (have it run the wax stats tool) and report back which bots succeeded and which failed.
2. From now on, whenever you spawn a new bot, include those same rules in its starting instructions before it begins any work.
3. Save this whole policy in wax as memory_type user_preference with session_id so you keep enforcing it across sessions.
```

The `.wax` file stays on the machine. The loopback bind is unreachable from outside. Full host playbook: [Resources/docs/wax-mcp-hosts.md](Resources/docs/wax-mcp-hosts.md).

</details>

Host install path (LaunchAgent `ai.wax.mcp-http`, `vector-health`, Hermes
doctors, recovery): [Resources/docs/wax-mcp-hosts.md](Resources/docs/wax-mcp-hosts.md).
Claude/doctor details: [Resources/docs/wax-mcp-setup.md](Resources/docs/wax-mcp-setup.md).

<p align="center">
  <img src="Resources/docs/assets/wax-cli-demo.gif" width="720" alt="Wax CLI demo TUI — live retrieval time, memory, FrameStore, concurrency, volume, errors, and exclusive lock">
</p>

---

## Foundation Models (iOS 26 / macOS 26)

Apple's on-device `LanguageModelSession` generates text. It does not keep a store across launches. Wax is that store: recall into the prompt, register memory tools, optionally write turns back.

Requires Apple Intelligence where the system model is available. Guard with `#if canImport(FoundationModels)` and `WaxFoundationModelsAvailability.current()`. Compilation on a machine without Apple Intelligence is not a successful `respond`.

```swift
import Foundation
import FoundationModels
import Wax

@available(iOS 26.0, macOS 26.0, *)
func chatWithMemory() async throws {
    let url = URL.documentsDirectory.appending(path: "assistant.wax")
    let memory = try await Memory(at: url)

    let session = memory.foundationModelsSession(
        instructions: "You are a helpful assistant with durable on-device memory."
    )

    switch WaxFoundationModelsAvailability.current() {
    case .available:
        let answer = try await session.respond(
            to: "I prefer dark mode and Vim keybindings."
        )
        print(answer)
    case .unavailable(let reason):
        print("Foundation Models unavailable: \(reason)")
    }

    try await session.close() // does not close `memory`
    try await memory.close()
}
```

`foundationModelsSession` is synchronous. It captures the `Memory` handle. Closing the session leaves the store open so other screens can share it.

Default config is hybrid:

| Piece | Behavior |
| --- | --- |
| Prompt | Recalls related memory and injects a `<wax_memory>` block |
| Tools | `waxRemember`, `waxRecall`, `waxSearch` (`.focused` kit) |
| Turns | Writes user and assistant turns when `persistencePolicy` allows it |

Attach tools to your own `LanguageModelSession`:

```swift
let tools = memory.foundationModelsTools(kit: .focused)
let session = LanguageModelSession(tools: tools) {
    "You have long-term memory via waxRemember / waxRecall / waxSearch."
}
```

Kits: `.focused` (default), `.compact`, `.combined`, `.focusedWithForget`. Full walkthrough: [Foundation Models](Resources/website/docs/ios/foundation-models.md).

---

## Swift app

Same engine inside an iOS or macOS app. No MCP process required.

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Wax.git", from: "0.1.41")
]
```

Or in Xcode: **File → Add Package Dependencies →** `https://github.com/christopherkarani/Wax.git`

```swift
import Foundation
import Wax

let url = URL.documentsDirectory.appending(path: "agent.wax")
let memory = try await Memory(at: url)

try await memory.save("The user is building a habit tracker in SwiftUI.")
let results = try await memory.search("What is the user building?")
if let best = results.items.first {
    print("Found: \(best.text)")
}

try await memory.close()
```

`Memory(at:)` auto-configures the on-device MiniLM embedder on iOS 18 / macOS 15+ (default `MiniLMEmbeddings` trait). Hybrid search is text until the embedder attaches; `vectorOnly` throws. Check `results.diagnostics` and `memory.stats()`.

<details>
<summary><strong>SwiftUI</strong></summary>

```swift
import SwiftUI
import Wax

struct ContentView: View {
    @State private var result = "Searching…"

    var body: some View {
        Text(result)
            .task {
                do {
                    let url = URL.documentsDirectory.appending(path: "agent.wax")
                    let memory = try await Memory(at: url)

                    try await memory.save("The user is building a habit tracker in SwiftUI.")
                    let context = try await memory.search("What is the user building?")

                    result = context.items.first?.text ?? "Nothing found"
                    try await memory.close()
                } catch {
                    result = "Error: \(error.localizedDescription)"
                }
            }
    }
}
```

</details>

Experimental Darwin facades: `PhotoMemory` / `VideoMemory` (OCR, keyframes, host-supplied transcripts; video does not store media bytes). Structured entities and facts are MCP/broker tools today (`entity_upsert`, `fact_assert`, `facts_query`). The Swift CRUD API for that graph is package-internal.

Public surface: [public-api.md](Resources/skills/public/wax/references/public-api.md). iOS docs: [christopherkarani.github.io/Wax](https://christopherkarani.github.io/Wax/).

### Run the demo

`Resources/WaxDemo` stress-tests `Memory` (save/search durability, embeddings, Foundation Models, errors). **macOS 26** for the demo package; Foundation Models mode needs Apple Intelligence.

```bash
cd Resources/WaxDemo
swift run WaxDemo --mode all
```

| Mode | What it runs |
|:-----|:-------------|
| `memory` | Save → search → close → reopen → search |
| `embeddings` | Built-in MiniLM + hybrid/vector search |
| `fm` | Foundation Models memory session (or a clear unavailable message) |
| `all` | Default |

```bash
swift run WaxDemo --mode fm --keep --store /tmp/wax-demo.wax
```

---

## Why this instead of what you already have

| Job | Typical option | Wax |
|:----|:---------------|:----|
| Scratchpad the host already has | `MEMORY.md` / `USER.md` / CLAUDE.md | Searchable across sessions and projects. Agents write lessons as they happen. You do not maintain the markdown by hand. |
| Hosted memory API | Mem0, SuperMemory, and similar | One file on disk. No account. `remember` does not call a cloud LLM to extract facts. |
| Markdown MCP | Basic Memory and similar | Binary store with FTS5 + CoreML vectors + WAL. AirDrop the file. Same MCP session loop. |
| Knowledge graph platform | Graphiti, Cognee | Different product: those want Neo4j/Postgres and an LLM for ingest. Wax is a local file plus an agent session loop. |
| Single-file RAG | Memvid `.mv2` and similar | Wax adds MCP `session_open` / `remember` / `recall` / `session_close`, a native Hermes provider, and Foundation Models tools. |
| Cloud vector DB | Pinecone, hosted Qdrant | Hybrid text + vector on Apple Silicon. p95 hybrid recall **6.1 ms** on the 2026-03-06 M-series sweep. |

Wax is the shared local store. It does not replace a temporal knowledge graph, and it does not claim LoCoMo numbers it has not published.

---

## Performance

Measured on Apple Silicon, 2026-03-06. Full report: [Resources/docs/benchmarks/2026-03-06-performance-results.md](Resources/docs/benchmarks/2026-03-06-performance-results.md).

```text
Hybrid recall p95     6.1 ms
Hybrid recall p99     6.5 ms
Cold open p95         9.2 ms
```

Cold open is store open only. The built-in embedder's first CoreML compile is a separate one-time cost; later launches reuse the cached compiled model.

Text search works with no embedder. Semantic search auto-configures MiniLM on iOS 18 / macOS 15+. The CLI and MCP server fail loud when hybrid/vector is requested without an embedder. The Swift SDK reports the mode that ran via `results.diagnostics`.

---

## Architecture

<details>
<summary><strong>How the file is laid out</strong></summary>

Wax bundles documents, metadata, and indexes in one binary. SQLite FTS5 for text. Metal-accelerated HNSW for vectors once an index holds 10,000+ vectors; smaller indexes use an exact Accelerate/CPU flat index with the same recall.

```text
┌──────────────────────────────────────────────────────────────────────────┐
│                          Dual Header Pages (A/B)                         │
│   (Magic, Version, Generation, Pointers to WAL & TOC, Checksums)         │
├──────────────────────────────────────────────────────────────────────────┤
│                          WAL (Write-Ahead Log)                           │
│   (Atomic ring buffer for crash-resilient uncommitted mutations)         │
├──────────────────────────────────────────────────────────────────────────┤
│                          Compressed Data Frames                          │
│   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐       │
│   │ Frame 0 (LZ4)    │  │ Frame 1 (LZ4)    │  │ Frame 2 (LZ4)    │ ...   │
│   │ [Raw Document]   │  │ [Metadata/JSON]  │  │ [System Info]    │       │
│   └──────────────────┘  └──────────────────┘  └──────────────────┘       │
├──────────────────────────────────────────────────────────────────────────┤
│                          Hybrid Search Indices                           │
│   ┌──────────────────────────────┐  ┌──────────────────────────────┐     │
│   │ SQLite FTS5 Blob             │  │ Metal HNSW Index             │     │
│   │ (Text Search + EAV Facts)    │  │ (Vector Search)              │     │
│   └──────────────────────────────┘  └──────────────────────────────┘     │
├──────────────────────────────────────────────────────────────────────────┤
│                          TOC (Table of Contents)                         │
│   (Index of all frames, parent-child relations, and engine manifests)    │
└──────────────────────────────────────────────────────────────────────────┘
```

Dual headers and the WAL keep the store consistent if the process dies mid-write. One query fans out to BM25 and HNSW. EAV facts ship through MCP tools.

</details>

---

## CLI

```bash
git clone https://github.com/christopherkarani/Wax.git
cd Wax
swift build -c release
cp .build/release/wax-cli /usr/local/bin/
```

```bash
wax-cli remember "An automobile needs periodic maintenance."
wax-cli search "car service" --mode hybrid --topK 3
wax-cli search "car service" --mode text
wax-cli demo --run
```

On Linux, build **without** `-DGRDBCUSTOMSQLITE` (that flag breaks GRDB's system SQLite overlay). MiniLM/vector search is Darwin; Linux is text-only unless you bring your own embedder:

```bash
swift build --product wax-cli --traits default,MCPServer
```

The npm package (`waxmcp`) is **darwin / arm64**. Linux and Intel Macs build from source.

<details>
<summary><strong>Daemon, compact, embed-backfill</strong></summary>

```bash
wax-cli daemon --store-path ~/.wax/memory.wax
```

```json
{"id":"1","command":"remember","content":"An automobile needs periodic maintenance."}
{"id":"2","command":"search","query":"car service","mode":"hybrid","topK":3}
{"id":"3","command":"shutdown"}
```

Offline maintenance always takes an explicit source, destination, and `--direct-store`. Work happens on a locked, byte-verified copy, then a staging file, then an atomic publish. The source is not modified.

```bash
wax-cli compact-store \
  --direct-store \
  --no-embedder \
  --store-path /path/to/source.wax \
  --output /path/to/compacted.wax

wax-cli embed-backfill \
  --direct-store \
  --store-path /path/to/source.wax \
  --output /path/to/backfilled.wax
```

Do not point these at a live broker store such as `~/.wax/memory.wax`. Stop attached writers first.

</details>

### WaxRepo

Semantic search TUI for git history (macOS):

```bash
wax-repo index
wax-repo search "where did we implement the WAL?"
```

---

## FAQ

**Do I need the internet?**  
No. Memory stays on device. The npm installer fetches the staged binaries once.

**How big is the file?**  
LZ4-compressed frames. Typical use is a few MB for thousands of documents.

**Can I sync across devices?**  
Yes. iCloud Drive, Dropbox, AirDrop. One file.

**What if the app crashes during a write?**  
WAL plus dual headers. The next open recovers.

**Does this run on Intel Macs?**  
The engine can run via Rosetta. Metal vector acceleration and the `waxmcp` npm package target Apple Silicon. Build `wax-cli` from source on Intel.

**I get "embedder unavailable" on hybrid search.**  
Hybrid and vector need a local embedding model. Swift `Memory(at:)` loads MiniLM on iOS 18 / macOS 15+, or set `Memory.Config.embedding = .custom(...)`. Older OS: text-only or bring your own embedder. CLI/MCP fail loud; Swift reports the effective mode on `diagnostics`.

**Two agents time out on the same store.**  
One writer. Start `~/.local/share/waxmcp/bin/start-wax-mcp-http.sh` and point every host at `http://127.0.0.1:3000/mcp`.

---

## Community

- [GitHub Issues](https://github.com/christopherkarani/Wax/issues)
- [Discord](https://discord.gg/NHgNh7HJ6M)
- [Star the repo](https://github.com/christopherkarani/Wax/stargazers)
- Docs: [iOS / Foundation Models](https://christopherkarani.github.io/Wax/) · [DocC](Sources/Wax/Wax.docc)

---

## License

Apache License 2.0. See [LICENSE](LICENSE).

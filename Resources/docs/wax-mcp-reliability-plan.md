# Wax MCP Reliability Plan

Operator feedback from coding agents (scores mostly 61–82/100) converges on one verdict: **handoff_latest works; recall and session identity do not earn the “chat dies, Wax does not” promise.** This document is the shared product plan for closing that gap.

Branch context: `feedback2`. No implementation commits are implied by this file alone.

---

## Problem statement

Agents treat Wax as optional context, not source of truth, because:

1. **Recall is the product and it misses the current repo.** Same-machine shared `~/.wax/memory.wax` returns high-ranked frames from other projects (rv, ryk, Espresso, Wax release notes) for Swarm / Espresso / ryk queries. `handoff_latest(project:)` finds the right note; hybrid `recall` often does not.
2. **Sessions die mid-run.** After long CI waits or broker process changes, `remember` / `handoff` fail with `session_id is not active in this broker process; call session_start again` even when the agent still holds the UUID.
3. **Close and write contracts are untrustworthy under load.** Agents report `session_end` looking “still active,” durable writes returning `pending` with `framesAdded: 0`, and parallel `handoff` + `session_end` racing.
4. **Protocol tax exceeds reliability.** Six-step open/close, ~25 tools/aliases, dual text+JSON payloads, and `session_id` omit-vs-present rules cause underuse (including 0/100 from never calling Wax).

The store and durable handoffs are fine. Retrieval defaults, lease/hop behavior, and agent-facing protocol are the score gap.

---

## Adversarial constraints (locked decisions)

These are the places earlier drafts contradicted themselves or ordered work so Phase 1 could make agents *worse*. Do not reopen without new evidence.

| # | Constraint |
|---|------------|
| C1 | **Empty project lane never auto-widens.** Default recall returns an explicit miss (`no frames for project P`) and empty top-K. Widening requires explicit `scope: global`. Do **not** implement “no P frames; showing global (N)” — that reintroduces silent contamination under a polite label. |
| C2 | **Identity before hard-filter.** Correct `project`/`repo` inference (git root, not worktree folder names) ships in the **same** Phase 1 slice as hard-filter, or hard-filter must not activate until inference is green. Filtering on a wrong stamped identity empties the lane or locks agents into the wrong project. |
| C3 | **Unlabeled frames are not “current project.”** Frames missing `wax.project` / `wax.repo` are excluded from default project-scoped recall. They appear only under `scope: global` (or an explicit migration/backfill). Do not invent project membership at read time. |
| C4 | **Resume is UUID-keyed, never agent+run steal.** On `_live` miss: if manifest for the supplied `session_id` is `.active`, rebind that UUID. If the UUID is ended/unknown, return structured error (`resumable: false`). Do **not** auto-attach a different session because `agent_id`+`run_id` matched. Sticky reuse stays behind explicit `session_resume` / fresh `run_id`. |
| C5 | **Pending writes are P0, not polish.** Success-shaped `status: pending` + `framesAdded: 0` trains agents to distrust every write. Block-until-searchable or return a non-success status in Phase 1; do not park this in Phase 3. |
| C6 | **Close is serialized per `session_id`.** `session_close` (or handoff→end) must be idempotent **and** mutually exclusive with concurrent `handoff`/`session_end` on the same id inside the broker. A new tool alone does not fix a race. |
| C7 | **Scope vocabulary is three values.** `scope`: `project` (default) \| `session` \| `global`. Drop `merged` and `include_foreign`. Today’s “session + durable merge” remains what `session_id` means on recall; it is not a separate scope enum value. |
| C8 | **Compat means additive args + predictable defaults, not identical rankings.** Old playbooks that omit `project` get cwd/session-inferred project scope. That will change top-K vs soft-boost ranking — intentional. Document it; do not keep soft-boost as the default under a feature flag forever. |
| C9 | **Phase exits are contracts, not score bands.** Operator 0–100 scores are diagnostic color, not KPIs. A phase is done when its T-contracts are green under default agent settings. |
| C10 | **“Soft-deprecate aliases” needs a mechanism.** MCP hosts advertise the full tool list. Soft-deprecation = shorter schemas + playbook/catalog pointing only at canonical verbs + `AgentInstructions` that never name aliases. Wishful “hide from agents” without host support is not a deliverable. |

---

## Goals

| Goal | Agent-facing success |
|------|----------------------|
| G1 Repo-first recall | Default `recall` for project P never ranks foreign-project **or unlabeled** frames in top-K. Same-project handoff that `handoff_latest` finds appears in top-K for identifier queries. Empty project lane returns an explicit miss and empty top-K (C1). |
| G2 Session survival | A persisted `session_id` survives broker restart / hop: next `remember` / `recall` / `handoff` rebinds **that** UUID when the manifest is `.active` (C4). Structured inactive errors distinguish resumable vs closed vs unknown. |
| G3 Honest lifecycle | `session_end` / close leaves no ambiguity that **this** session is closed. Atomic close is idempotent and broker-serialized (C6). Agents are not required to end between turns of one host chat. |
| G4 Cheap default loop | Productive path is ≤2 round-trips (`session_open` then work). Canonical verbs are few; aliases are absent from playbook/`AgentInstructions` (C10). |
| G5 Trustworthy writes | A successful `remember` returns a real frame id and `framesAdded ≥ 1`, or an explicit **non-success** status. Never a success-shaped `pending` with zero frames (C5). |

Non-goals for this plan: public Swift `Memory` API redesign, entity/fact graph overhaul, embedder model swap, marketing adoption outside MCP + playbook + optional harness auto-open.

---

## Current system (facts implementers must not rediscover)

| Fact | Location / implication |
|------|------------------------|
| `recall` has **no** `project` / `scope` argument today | `AgentBrokerCommandSurface`: `query`, `limit`, `session_id`, `mode`, `alpha`, `search_top_k`, `topK`, `filters` only. Soft boosts via `MemorySemantics.rankingReasons` (+0.9 repo / +0.7 project). |
| `handoff_latest` **hard-filters** `project` | Pattern to copy for recall defaults (`Wax.latestCommittedActiveHandoffMeta`). |
| `"not active in this broker process"` means UUID ∉ this process `_live` | `VirtualSessionStore.notActiveError` / `AgentBrokerService` validate path. Lease TTL (`defaultSessionLeaseSeconds = 300`) is written/refreshed; it is **not** the mid-run eviction mechanism. |
| Broker hop / restart drops `_live` | Disk manifests remain; `resume` / `recovered_lease` exists, but write paths do not auto-rebind on miss — they throw. |
| `session_end` returns `active: false` for the ended session | `AgentBrokerService.sessionEndPayload`. `remaining_active` / `active_session_count` are **siblings**. Agent reports of `active: true` are likely misreads of sibling fields + duplicate JSON + weak summary text — fix contract clarity and rendering, then verify. |
| `metadata.session_id` is rejected | Intentional; top-level `session_id` only. |
| MCP results duplicate JSON in text + resource blocks | `WaxMCPTools.jsonResult` / `textWithJSONResourceResult`. |
| Durable remember can ack `pending` while embedder loads | `AgentBrokerService` returns `status: "pending"`, `framesAdded: 0` when `shouldDeferRememberUntilEmbedderReady()`; settles via `pendingRememberWrites`. Agents cannot treat this as stored. |
| Docs disagree on recall + `session_id` | `project-rules.md` (merge vs durable-only) is correct vs code; `wax-mcp-hosts.md` line “with `session_id` for this task only” is wrong (that describes `search`). |
| cwd inject exists; git-root inference exists in semantics | MCP injects `cwd` for some commands; `MemorySemantics` already has `gitRepositoryRoot` — worktree folder names still leak when callers stamp identity from basename of cwd. |

---

## Phased work

### Phase 0 — Lock the diagnosis (tests first)

Turn operator stories into **failing asserts** before behavior changes. `XCTSkip` / issue-linked skips are **not** an exit — they are a temporary WIP marker that must convert to red asserts before Phase 1 merges.

| ID | Contract |
|----|----------|
| T0.1 | Durable frames for projects A and B (both labeled); session scoped to A; default `recall` about A → B absent from top-K. Unlabeled frame U also absent. Both B and U appear only under `scope: global`. |
| T0.2 | Handoff with `project=X` found by `handoff_latest(X)` also appears in default `recall` top-K for the same identifiers (text-first acceptable if hybrid degraded). |
| T0.3 | Start session in process A; new broker / empty `_live`; `remember(session_id)` rebinds when manifest is `.active` — does not 400 with “call session_start again”. Supplying only `agent_id`+`run_id` must **not** attach a different UUID. |
| T0.4 | After `session_end`, agent-facing summary cannot be read as “this session still open”; sibling `remaining_active` is unambiguous. Concurrent `handoff` ∥ `session_end` on same id does not leave a half-closed session. |
| T0.5 | Embedder-loading path: response is not success-shaped with `framesAdded: 0` (either wait until searchable with `framesAdded ≥ 1`, or non-success status agents must treat as failure/retry). |
| T0.6 | Worktree cwd under a git root stamps `project`/`repo` from the **repository root name** (or explicit override), never from `worktree-…` basename. Wrong stamp fails the suite. |

**Exit:** T0.1–T0.6 exist as failing (or newly green) asserts under `--traits MCPServer` where applicable. Doc-only: fix `wax-mcp-hosts.md` recall line immediately (reduces agent harm; does not count as Phase 1).

### Phase 1 — P0 product fixes

Score bands (“~61 → ~80”) are not exit criteria (C9). Exit = contracts below green.

#### 1.0 Project identity (blocks 1.1) — C2, T0.6

- Infer `project`/`repo` from git repository root (reuse/extend `MemorySemantics` git helpers), not worktree directory basenames.
- Fail closed: if inference is null and no explicit `project` / session project, default recall behaves as empty project lane (explicit miss) — do not soft-boost the whole shared store under a guessed name.
- Writes that omit project still persist; they remain **unlabeled** (C3) until caller or backfill sets metadata.

#### 1.1 Repo-first recall (G1) — C1, C3, C7, T0.1–T0.2

- Add first-class `project` / `repo` / `scope` (`project` \| `session` \| `global`) on `recall`.
- Default `scope: project`: hard-filter to session project or inferred project; exclude foreign **and** unlabeled frames from top-K.
- Empty project lane: explicit miss + empty top-K. No auto-global fallback.
- Identifier / lexical-first for PR numbers, type names, repo names (extend existing identifier rerank).
- When `embeddingStatus=degraded`, prefer text or text-gated hybrid so vectors cannot outrank same-project lexical hits.

#### 1.2 Session survival across broker hops (G2) — C4, T0.3

- On `_live` miss with persisted `.active` manifest for the **supplied** `session_id`: auto-rebind, refresh lease, proceed.
- Structured inactive errors: `{ code, resumable, reason }` — not only “call session_start again”.
- Do not “fix” mid-CI death by only lengthening lease TTL; fix hop identity.
- `agent_id`+`run_id`: refuse silent cross-UUID attach. Prefer explicit `session_resume` or fresh `run_id` for a new host chat. Optional: return last writer `session_id` from `handoff_latest` only when that session is still `.active` (never recommend an ended UUID).

#### 1.3 Honest close (G3) — C6, T0.4

- Keep ended-session `active: false`; front-load an unambiguous one-line summary; isolate or rename sibling fields so they cannot be read as “this session”.
- Add atomic `session_close(session_id, handoff, pending_tasks)` (handoff then end, idempotent).
- Broker: serialize close/handoff/end for a given `session_id` so parallel tool calls cannot interleave.
- Playbook: do not require `session_end` between user turns in one host chat; end on chat close or idle.

#### 1.4 Trustworthy writes (G5) — C5, T0.5

- Remove success-shaped pending-zero acks from the default agent path.
- Preferred: await embedder readiness (with a bounded timeout) then return `status: ok` + `framesAdded ≥ 1` + frame id(s).
- On timeout / hard failure: `status: error` (or equivalent non-success) — never `ok`/`pending` with zero frames that agents summarize as success.
- Settle-on-close already exists (`settlePendingRememberWrites`); do not rely on agents calling `session_end` to make mid-run remembers real.

**Exit:** T0.1–T0.6 green under default agent settings. Operator replay: Swarm/Espresso-style project query returns no foreign top hits; empty lane does not dump global.

### Phase 2 — P1 ergonomics

#### 2.1 Cheap open and one write API (G4) — C10

- `session_open(project?, agent_id?, run_id?, recall_query?)` → `{session_id, handoff, recall?, project, repo}`.
- `remember(content, scope: session|durable, type?, project?)` — stop teaching “omit session_id = durable” as the only rule (keep omit-compat short-term).
- Canonical verbs in playbook + `AgentInstructions`: `session_open`, `remember`, `recall`, `session_close`, `stats`. Aliases remain callable for compat but are absent from paste blocks and default blurbs.

#### 2.2 Output and discovery tax

- `verbosity: compact` — single structured object; no duplicate text+resource JSON for the same payload.
- Shorter default tool blurbs; full schema on demand.

#### 2.3 Playbook alignment

- Keep `wax-mcp-hosts.md`, `project-rules.md`, `AgentInstructions.swift`, and AGENTS/CLAUDE paste blocks in lockstep with Phase 1 defaults (project-scoped recall, UUID rebind, honest writes).

**Exit:** New agent can become productive in ≤2 MCP round-trips. Paste blocks never instruct alias tools or “omit session_id = durable” as the sole write rule.

### Phase 3 — P2 polish (capacity-gated)

| Item | Intent |
|------|--------|
| Decision / constraint lane | Not hybrid-ranked against ephemeral task notes (within project scope). |
| Child / swarm memory | Parent auto-write on spawn/return, or session-scoped remember for children. |
| Ops | WAL checkpoint / session WAL hygiene; multi-stdio → one shared HTTP broker docs + detection. |
| Diagnostics | `lease_status`, `lease_owner`, clearer counters (`totalFrameCount` scope). |
| Latency | Budget small writes; avoid multi-second ceremony for tiny notes (without reintroducing pending-zero). |
| Adoption | Optional harness auto-prime (`handoff_latest` + `session_start` / `session_open`) so “never called” stops scoring absence. |
| Unlabeled backfill | Optional offline job to stamp `wax.project` from handoff/project heuristics — **not** required for Phase 1 (C3). |

---

## Suggested delivery order

1. Phase 0 contracts T0.1–T0.6 + `wax-mcp-hosts.md` recall correction  
2. **Project identity (1.0) and hard project filter + miss messaging (1.1) in one slice**  
3. Auto-rebind supplied `session_id` across broker hops + structured inactive errors (1.2)  
4. Close payload clarity + serialized `session_close` (1.3)  
5. Honest remember / kill pending-zero success shape (1.4)  
6. `session_open` + `remember(scope:)` + playbook collapse (2.1)  
7. Compact verbosity + catalog/blurb trim (2.2)  
8. Phase 3 items as capacity allows  

Prefer small, green commits. Args stay additive. Ranking under default `scope: project` **will** change (C8) — call that out in release notes / playbook, not as a silent surprise.

---

## Mission-critical files

Read in this order before changing behavior:

1. `Sources/Wax/Broker/AgentBrokerService.swift` — recall merge, remember (incl. pending path), session_end, settlePending  
2. `Sources/Wax/Broker/VirtualSessionStore.swift` — `_live`, lease, not-active, agent+run reuse, resume  
3. `Sources/Wax/MemorySemantics.swift` — ranking boosts, write defaults, git-root inference  
4. `Sources/Wax/UnifiedSearch/UnifiedSearch.swift` — hybrid / identifier rerank  
5. `Sources/WaxMCPServer/WaxMCPTools.swift` — aliases, cwd inject, dual content blocks  
6. `Sources/WaxMCPServer/ToolSchemas.swift` + `AgentInstructions.swift`  
7. `Sources/Wax/Broker/AgentBrokerCommandSurface.swift`  
8. `Sources/WaxCore/Wax.swift` — handoff project hard-filter  
9. `Sources/Wax/Orchestrator/MemoryOrchestrator.swift` — recall execution / handoff  
10. `Resources/skills/public/wax-mcp/references/project-rules.md`  

**Tests to extend:**  
`Tests/WaxMCPServerTests/BrokerSessionModelRegressionTests.swift`,  
`Tests/WaxTests/VirtualSessionStoreTests.swift`,  
plus new contamination / broker-hop / pending-write / worktree-identity cases (Phase 0).

**Verify:** targeted `swift test --filter …` (MCP cases need `--traits MCPServer`). Do not start with unfiltered full suite.

---

## Feedback map (why each phase exists)

| Operator theme | Phase |
|----------------|-------|
| Cross-project recall contamination; handoff beats RAG | 1.0 + 1.1 |
| Session not active after CI / broker hop | 1.2 |
| `session_end` contradictory / active confusion | 1.3 |
| Race: handoff ∥ session_end | 1.3 |
| Six-step ritual; adoption friction | 2.1 |
| Two-horizon omit/`session_id` footgun | 2.1 |
| Tool sprawl / aliases | 2.1 (C10) |
| Duplicate JSON payloads; huge schemas | 2.2 |
| Wrong worktree project identity | 1.0 (was wrongly deferred) |
| Sticky wrong `agent_id`+`run_id` session | 1.2 (C4) |
| `pending` + `framesAdded: 0` | 1.4 (was wrongly Phase 3) |
| Children have no Wax | 3 |
| WAL / multi-process lock | 3 |
| Latency / diagnostics | 3 |

Operator scores (illustrative only): 0 (never called), 61–64 (handoff-only / lease death), 68–72 (ceremony tax), 82 (content good, lifecycle/ergonomics polish). Use them to prioritize themes; use T-contracts to ship.

---

## Out of scope

- Changing the public Swift app API (`Memory` / Photo / Video facades)  
- Replacing MiniLM or rebuilding the embedding stack  
- Making structured `entity_*` / `fact_*` the default coding-agent path  
- Committing private scratchpads, score ledgers, or marketing drafts into this tree  
- Treating unlabeled historical frames as belonging to “whatever cwd is now” without an explicit backfill  

---

## Working notes

- Treat this file as the **shared product plan**, not a personal todo log. Update phase exits when contracts land; avoid daily checklist churn.  
- Private execution notes stay outside the public tree (see `AGENTS.md` hygiene).  
- When a phase completes, prefer a short durable `remember` (decision/lesson) over expanding this document with narrative history.

### Phase exit status (feedback2)

| Phase | Status |
|-------|--------|
| 0 (T0.1–T0.6 + hosts recall fix) | Done — `Tests/WaxMCPServerTests/WaxMCPReliabilityPlanContractsTests.swift` |
| 1.0–1.4 | Done — identity, hard-filter recall, UUID rebind, `session_close`, honest remember |
| 2.1–2.3 | Done — `session_open`, `remember(scope:)`, compact verbosity, playbook lockstep |
| 3 | Not started (capacity-gated) |

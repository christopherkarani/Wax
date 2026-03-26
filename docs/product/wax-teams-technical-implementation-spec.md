# Wax Teams Technical Implementation Spec

## Purpose

This document translates the Wax Teams product spec into a concrete implementation plan for Wax CLI and Wax MCP.

It is intentionally scoped to Wax's current strengths:

- local-first execution
- single-machine coordination
- deterministic persistence
- bounded concurrency

## Goals

1. Preserve Wax's strong single-agent memory path.
2. Add a clear coordination model for multiple local coding-agent sessions.
3. Avoid silent behavior changes between text-only and vector-capable flows.
4. Keep the architecture simple enough to ship and debug.

## Non-Goals

This design does not attempt to provide:

- distributed locking across machines
- multi-host coordination
- hosted realtime sync
- unbounded parallel writes to one shared vector store

## System Surfaces

Wax Teams should expose two primary surfaces.

### MCP Surface

Best for:

- one long-lived agent process
- durable personal/project memory
- repeated vector recall without repeated embedder warmup

Current implementation base:

- [`MCPMemoryFactory.swift`](/Users/chriskarani/CodingProjects/AIStack/Agents/Wax/Sources/WaxMCPServer/MCPMemoryFactory.swift)
- [`WaxMCPTools.swift`](/Users/chriskarani/CodingProjects/AIStack/Agents/Wax/Sources/WaxMCPServer/WaxMCPTools.swift)

### CLI Surface

Best for:

- local shell usage
- handoffs
- lightweight inter-agent coordination
- repeated vector operations via the auto-daemon path

Current implementation base:

- [`AgentDaemonClient.swift`](/Users/chriskarani/CodingProjects/AIStack/Agents/Wax/Sources/WaxCLI/AgentDaemonClient.swift)
- [`DaemonCommand.swift`](/Users/chriskarani/CodingProjects/AIStack/Agents/Wax/Sources/WaxCLI/DaemonCommand.swift)
- [`StoreSession.swift`](/Users/chriskarani/CodingProjects/AIStack/Agents/Wax/Sources/WaxCLI/StoreSession.swift)

## Memory Scopes

Wax Teams should standardize three store roles.

### Personal Store

Recommended path:

- `~/.wax/memory.wax`

Responsibilities:

- user preferences
- project conventions
- validated architectural decisions
- durable knowledge promoted from sessions

Access pattern:

- primarily MCP
- CLI allowed for promotion and inspection

### Session Store

Recommended path:

- `~/.wax/sessions/<session-id>.wax`

Responsibilities:

- current task state
- transient debugging findings
- local scratch notes
- partial work products

Access pattern:

- one store per agent session
- direct CLI usage
- optional session-scoped MCP in the future

### Coordination Store

Recommended path:

- `~/.wax/projects/<project-id>/coordination.wax`

Responsibilities:

- handoffs
- task claims
- blockers
- work updates
- recent activity feed

Access pattern:

- shared CLI usage from multiple agent sessions on the same machine
- MCP query support can be added later if needed

## Concurrency Model

This part is critical.

Wax currently uses exclusive locking for a store while an open `MemoryOrchestrator` holds it.

Implications:

### Same Store, Same Host

- one daemon owns the store
- all CLI clients using that store route to the same daemon
- requests are serialized

This is acceptable for:

- coordination
- handoffs
- low-frequency shared memory traffic

This is not ideal for:

- many agents issuing heavy concurrent vector writes to one shared store

### Different Stores

- each store gets its own daemon
- each daemon loads its own embedder state
- sessions run independently

This should be the default multi-agent operating model.

## Recommended Operating Pattern

For `N` local coding agents:

1. Each agent gets its own session store.
2. All agents may optionally share one coordination store.
3. Durable insights are promoted into the personal store.

This creates:

- high isolation for active work
- low-friction coordination
- clean durable memory

## Data Model

Every stored coordination record should carry explicit metadata.

Required metadata:

- `wax.scope`
- `wax.project_id`
- `wax.agent_id`
- `wax.session_id`
- `wax.task_id`
- `wax.event_type`
- `wax.created_at`

Recommended event types:

- `note`
- `handoff`
- `task_claimed`
- `task_updated`
- `task_blocked`
- `task_completed`
- `finding`
- `decision`

Optional metadata:

- `wax.parent_event_id`
- `wax.priority`
- `wax.owner`
- `wax.tags`

## Command Surface

The product should preserve existing primitives and add coordination-focused ones.

### Existing Commands To Keep

- `remember`
- `recall`
- `search`
- `handoff`
- `handoff-latest`
- `stats`
- `flush`

### New CLI Commands To Add

#### `coordination-post`

Purpose:

- write a structured coordination event

Example responsibilities:

- publish a blocker
- record a finding
- leave a handoff

Arguments:

- `--project-id`
- `--agent-id`
- `--session-id`
- `--task-id`
- `--event-type`
- `--content`
- repeatable `--metadata`

#### `coordination-feed`

Purpose:

- return recent events for a project coordination store

Arguments:

- `--project-id`
- `--limit`
- optional `--event-type`
- optional `--agent-id`

#### `coordination-open-blockers`

Purpose:

- list unresolved blockers

Arguments:

- `--project-id`
- optional `--agent-id`
- `--limit`

#### `coordination-claim`

Purpose:

- claim a task in shared memory

Arguments:

- `--project-id`
- `--agent-id`
- `--session-id`
- `--task-id`
- optional `--summary`

#### `coordination-complete`

Purpose:

- mark a task as completed

Arguments:

- `--project-id`
- `--agent-id`
- `--session-id`
- `--task-id`
- optional `--summary`

## Query Model

Coordination queries should remain simple and reliable.

Preferred implementation:

- store coordination events as normal frames with structured metadata
- use text search plus metadata filtering first
- add hybrid/vector search where it helps summaries and handoffs

This avoids prematurely building a separate task database.

## Daemon Strategy

The current auto-daemon behavior is a good base for agent mode.

### Current Behavior

- vector-capable CLI commands auto-start a daemon
- daemon is keyed by store path plus embedder choice
- same store resolves to same daemon socket
- text-only commands stay one-shot

Relevant files:

- [`AgentDaemonClient.swift`](/Users/chriskarani/CodingProjects/AIStack/Agents/Wax/Sources/WaxCLI/AgentDaemonClient.swift)
- [`DaemonCommand.swift`](/Users/chriskarani/CodingProjects/AIStack/Agents/Wax/Sources/WaxCLI/DaemonCommand.swift)

### Product Requirement

Agent-facing tools should not need to learn special daemon commands.

Required behavior:

1. Normal vector-capable CLI commands transparently reuse the daemon.
2. Text-only commands remain lightweight.
3. Daemon startup failures fall back safely.
4. Vector-required flows fail loudly if vector is unavailable.

## Store Layout

Recommended default layout:

```text
~/.wax/
  memory.wax
  sessions/
    <session-id>.wax
  projects/
    <project-id>/
      coordination.wax
```

Implementation note:

- this layout should be standardized in CLI helpers rather than left entirely to user convention

## Implementation Phases

### Phase 1: Formalize Memory Roles

Ship:

- documented personal/session/coordination scopes
- path helpers for session and coordination stores
- consistent metadata schema for coordination records

Code areas:

- `Sources/WaxCLI/StoreOptions.swift`
- new CLI path helper module
- docs and setup guides

### Phase 2: Coordination Primitives

Ship:

- `coordination-post`
- `coordination-feed`
- `coordination-open-blockers`
- `coordination-claim`
- `coordination-complete`

Implementation approach:

- build on top of existing `remember/search/recall`
- encode event records in metadata
- keep output available in text and JSON

### Phase 3: Agent-Friendly Defaults

Ship:

- optional `--project-id` driven automatic coordination-store resolution
- optional session-id generation helpers
- optional `agent mode` wrapper command for startup convenience

This phase is about reducing prompting burden for agents.

### Phase 4: MCP Coordination Queries

Ship:

- read-focused MCP tools over the coordination store
- project feed
- blockers
- latest handoffs

Do not start with MCP coordination writes unless there is a strong usage reason.

## Failure Modes And Handling

### Embedder Unavailable

Behavior:

- text-only commands may continue without vector
- vector-required commands must fail explicitly

### Store Lock Contention

Behavior:

- fail fast with explicit lock-timeout errors
- do not hang indefinitely

### Daemon Startup Failure

Behavior:

- fall back to one-shot for ordinary CLI flows
- preserve explicit failure for vector-required operations when necessary

### Shared Store Overuse

Behavior:

- document that one coordination store is serialized
- recommend per-agent session stores for heavy active work

## Verification Strategy

Required tests:

1. session-store path generation
2. coordination-store path generation
3. structured coordination record round-trip
4. recent-feed query correctness
5. blocker filtering correctness
6. task claim/complete round-trip
7. daemon reuse across repeated vector commands
8. lock-timeout behavior under shared-store contention

Required smoke checks:

1. two sessions writing to one coordination store through the shared daemon
2. two sessions writing independently to separate session stores
3. promotion from session store to personal store

## Product Risks

1. Users may overuse one shared coordination store and expect high parallel throughput.
2. Metadata conventions may drift unless enforced in helpers.
3. Too many manual flags will make agent prompting brittle.

## Mitigations

1. Default to one session store per agent.
2. Provide dedicated coordination commands instead of raw metadata-only conventions.
3. Keep agent-facing defaults simple and documented.

## Recommendation

The product should ship as:

- Wax MCP for long-lived personal memory
- Wax CLI for per-session work and local coordination
- structured coordination primitives on top of shared project stores

This is the cleanest path that matches Wax's current architecture and avoids overpromising distributed collaboration.

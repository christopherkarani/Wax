# Wax Teams Product Spec

## Summary

Wax Teams is a local-first memory product for coding agents. It combines:

- personal memory for one active agent
- session memory for in-progress work
- shared coordination memory for multiple local agents

The product should lean into Wax's real strengths:

- fast local persistence
- deterministic retrieval
- single-user and single-machine workflows
- durable memory without cloud dependency

It should not start as a distributed cloud collaboration system.

## Positioning

Wax Teams is shared memory infrastructure for local agent workflows.

Core promise:

"Your agents keep context, hand work to each other, and resume where they left off without relying on a hosted memory backend."

## Target User

Primary users:

- solo developers using Codex, Claude Code, and terminal agents
- technical users running multiple coding-agent sessions on one machine
- teams that want private, local-first agent memory before they need cloud sync

## Jobs To Be Done

1. Let one agent remember project context across sessions.
2. Let multiple agents coordinate through shared memory.
3. Let users promote temporary insights into durable project knowledge.
4. Let a user inspect what agents learned, tried, and left behind.

## Non-Goals

Not a v1 goal:

- large-team enterprise collaboration
- cross-region shared memory
- high-throughput multi-writer vector serving
- real-time hosted sync
- replacing source control or issue tracking

## Product Model

Wax Teams has three memory scopes.

### 1. Personal Store

Purpose:

- user preferences
- durable project facts
- architecture decisions
- recurring patterns

Properties:

- long-lived
- private to the user
- default source for long-term recall

### 2. Session Store

Purpose:

- task-local scratchpad
- experiments and hypotheses
- temporary findings
- current task progress

Properties:

- one store per agent session
- disposable or archivable
- best for active work

### 3. Coordination Store

Purpose:

- handoffs between agents
- shared task status
- blockers
- findings
- recommendations

Properties:

- shared by multiple local agents
- optimized for lightweight coordination
- not intended as a high-concurrency global vector service

## Primary Workflows

### Single-Agent Recall

1. Agent starts.
2. Agent loads personal and project memory.
3. Agent continues work with prior context.

### Agent Handoff

1. Agent A writes what it tried, what worked, and what is blocked.
2. Agent B reads the latest handoff.
3. Agent B resumes without repeating exploratory work.

### Shared Coordination

1. Agents write claims, updates, blockers, and completions to the coordination store.
2. Agents query recent changes and open blockers.
3. The user or another agent can reconstruct current project state.

### Promotion

1. Session insight proves durable.
2. It is promoted into personal or project memory.
3. Future sessions recall it automatically.

## MVP Feature Set

1. Personal, session, and coordination store concepts.
2. `remember`, `recall`, and `search`.
3. `handoff` and `handoff-latest`.
4. Shared task primitives:
   - claim
   - update
   - blocked
   - complete
5. Metadata tagging on every write.
6. Recent activity and open blocker queries.
7. MCP support for long-lived agent memory.
8. CLI support for local multi-agent coordination.

## UX Principles

- Default to simple memory scopes the user can understand.
- Do not expose raw storage mechanics unless the user wants them.
- Make handoffs and coordination first-class, not bolted-on notes.
- Avoid silent downgrade behavior when vector workflows are requested.
- Keep local-first and privacy-first as product assumptions.

## Why This Product Fits Wax

Wax is already strongest where this product needs strength:

- local persistence
- deterministic retrieval
- low-latency single-machine usage
- repeatable agent recall

The best near-term product is not "memory for everyone everywhere."
It is "memory that makes local agents materially better at continuing work and collaborating."

## Success Criteria

The MVP is successful if:

1. A single agent can resume useful project context across days.
2. Two or more agents can hand work off cleanly.
3. A shared coordination store answers "what changed" and "what is blocked" quickly.
4. Durable knowledge promotion becomes a normal workflow.
5. Users trust the product because state stays local and behavior is predictable.

## Version 1 Pitch

Wax Teams gives coding agents durable local memory:

- personal memory for deep context
- session memory for active work
- shared coordination memory for handoffs and collaboration

## Roadmap Direction

After MVP, possible expansions are:

- project-level dashboards
- memory inspection UI
- richer task and ownership models
- optional export, archive, and sync workflows

Those should only come after the local-first single-machine workflow is strong.

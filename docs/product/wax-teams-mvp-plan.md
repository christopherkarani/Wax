# Wax Teams MVP Plan

## Purpose

This plan covers what is still missing to turn Wax from a strong engine and toolchain into a real product MVP that users can adopt, understand, and pay for.

It focuses on these missing areas:

- coordination commands
- metadata standards in the actual product surface
- coordination store defaults
- recent activity and blocker queries
- UX layer
- onboarding and install flow for non-technical users
- licensing and billing

## MVP Outcome

The MVP is ready when a user can:

1. Install Wax without manual repo builds.
2. Connect Wax to Codex or Claude with minimal setup.
3. Use one personal memory store, one session store, and one coordination store without needing to invent their own conventions.
4. Run multiple local coding-agent sessions that can leave handoffs, claims, blockers, and updates in a shared coordination store.
5. Inspect current project activity and open blockers from a simple UX layer.
6. Understand what is free, what is paid, and how to activate the paid tier.

## Guiding Constraints

- Keep Wax local-first.
- Do not overbuild distributed collaboration.
- Make the CLI and MCP product surfaces consistent.
- Prefer explicit metadata and explicit store roles over hidden conventions.
- Keep agent prompting simple. Agents should not need long custom instructions to use the product correctly.

## Workstreams

## 1. Coordination Commands

### Goal

Give users and agents a first-class command surface for shared coordination instead of requiring raw `remember` plus ad hoc metadata.

### Deliverables

1. `coordination-post`
2. `coordination-feed`
3. `coordination-open-blockers`
4. `coordination-claim`
5. `coordination-complete`

### Scope

Each command should:

- support JSON and text output
- write or query the coordination store
- enforce required metadata
- work with the CLI auto-daemon path when vector is enabled

### Design Rules

- `coordination-post` is the generic primitive
- the other commands are specialized ergonomic wrappers
- all writes should emit consistent machine-readable fields
- no silent downgrade of command semantics

### Acceptance Criteria

1. Two local agent sessions can post and retrieve coordination events from the same project store.
2. A task can be claimed, updated, blocked, and completed through dedicated commands.
3. All command outputs are stable in JSON for agent use.

## 2. Metadata Standards

### Goal

Make agent, project, task, and scope metadata part of the actual product surface, not just a convention in docs.

### Required Metadata

- `wax.scope`
- `wax.project_id`
- `wax.agent_id`
- `wax.session_id`
- `wax.task_id`
- `wax.event_type`
- `wax.created_at`

### Optional Metadata

- `wax.parent_event_id`
- `wax.priority`
- `wax.owner`
- `wax.tags`
- `wax.status`

### Deliverables

1. Shared metadata builder/helper in CLI code
2. Validation rules for required coordination fields
3. Docs explaining the schema
4. Regression tests for metadata round-trips

### Acceptance Criteria

1. Coordination commands always write the required metadata.
2. Query commands can filter on project, agent, task, and event type.
3. Documentation and CLI help output use the same field names.

## 3. Coordination Store Defaults

### Goal

Remove ambiguity about where coordination data lives and how users should structure it.

### Default Layout

```text
~/.wax/
  memory.wax
  sessions/
    <session-id>.wax
  projects/
    <project-id>/
      coordination.wax
```

### Deliverables

1. Path helpers for personal, session, and coordination stores
2. `--project-id` driven coordination-store resolution
3. Session-id generation helper or command
4. Docs and examples using the standard paths

### Acceptance Criteria

1. Users can run coordination commands with `--project-id` and no manual store path.
2. Multiple sessions using the same `project-id` resolve to the same coordination store.
3. Session-store defaults are distinct from coordination-store defaults.

## 4. Recent Activity And Blocker Queries

### Goal

Expose the coordination store as useful project state, not just a bucket of notes.

### Deliverables

1. Recent activity feed
2. Open blockers query
3. Latest handoff query per project
4. Optional filtering by agent, task, and event type

### Query Priorities

Primary questions the product must answer:

- what changed recently?
- what is blocked?
- who is working on what?
- what should the next agent pick up?

### Acceptance Criteria

1. A project with multiple events can return the latest activity in correct order.
2. Blockers can be listed without returning resolved items.
3. A user or agent can identify the latest useful handoff in one command.

## 5. UX Layer

### Goal

Provide a product surface that non-terminal users can actually understand and navigate.

### MVP UX Choice

The fastest credible MVP is a local desktop or web UI with these views:

1. Memory scopes
2. Project coordination feed
3. Open blockers
4. Latest handoffs
5. Memory item inspector

### Recommended MVP Surface

Start with a lightweight local web UI or macOS app shell rather than a large cross-platform app.

### Required MVP Screens

1. Home
   - recent projects
   - connection status
   - active stores
2. Project View
   - recent coordination feed
   - open blockers
   - active tasks
3. Memory Inspector
   - stored item content
   - metadata
   - source scope
4. Setup
   - install status
   - MCP connection status
   - CLI/daemon health

### Acceptance Criteria

1. A non-technical user can see what agents are doing without using the CLI.
2. The UI reflects project coordination state from the shared store.
3. Setup status is visible and actionable.

## 6. Onboarding And Install Flow

### Goal

Make initial setup workable for users who are not building Wax from source.

### Deliverables

1. Published package and binaries
2. One-command install flow
3. MCP install flow for Codex and Claude
4. First-run setup check
5. Troubleshooting surface for embedder, daemon, and store issues

### Target Experience

User flow:

1. Install Wax
2. Run setup
3. Connect Claude or Codex
4. Create or select a project
5. Start using personal and coordination memory

### Acceptance Criteria

1. A new user on a fresh machine can install and connect without reading repo internals.
2. The setup flow confirms MCP registration and runtime readiness.
3. Common failure states are surfaced with direct fixes.

## 7. Licensing And Billing

### Goal

Turn Wax into a sellable product without compromising the open-source adoption path.

### Product Tiers

#### Free

- core CLI
- core MCP
- local memory engine
- basic coordination commands

#### Pro

- memory browser UI
- project coordination UI
- improved setup and diagnostics
- advanced memory inspection and cleanup

#### Teams

- shared project coordination features
- team/project dashboards
- audit trail
- admin and project controls

#### Enterprise

- self-hosting
- SSO
- policy and audit controls
- support and SLA

### Deliverables

1. License strategy
2. Feature gating plan
3. Activation flow
4. Pricing page draft
5. Billing backend decision

### Acceptance Criteria

1. Users can clearly tell what is free and what is paid.
2. Paid features are gated cleanly without breaking core OSS usage.
3. Activation does not block local-first core functionality.

## Phased Delivery

## Phase 1: Product Foundation

Scope:

- metadata standards
- coordination store defaults
- store/path helpers
- docs refresh

Exit Criteria:

- personal/session/coordination stores are first-class and standardized
- metadata schema exists in code and docs

## Phase 2: Coordination MVP

Scope:

- coordination commands
- recent activity query
- blockers query
- latest-handoff query
- regression tests

Exit Criteria:

- two or more local agents can coordinate through a shared project store
- JSON output is stable enough for agent consumption

## Phase 3: Product UX And Setup

Scope:

- setup flow
- install diagnostics
- local UI shell
- project and memory views

Exit Criteria:

- a non-technical user can install and inspect memory without terminal-only workflows

## Phase 4: Monetization Layer

Scope:

- licensing strategy
- billing integration
- feature gating
- pricing page and activation flow

Exit Criteria:

- the product can be sold without ambiguity about free versus paid capabilities

## Suggested Build Order

1. metadata standards
2. coordination store defaults
3. coordination commands
4. recent activity and blockers queries
5. setup flow
6. UX layer
7. licensing and billing

This order matters because the UX and billing layers should sit on top of a stable command and data model.

## Risks

### Risk 1: Shared-store expectations are too high

Users may assume one shared coordination store can support unlimited high-frequency concurrent vector work.

Mitigation:

- document serialized shared-store behavior
- recommend per-agent session stores for active work

### Risk 2: Metadata drift

Ad hoc writes can weaken query quality and UX consistency.

Mitigation:

- central metadata helpers
- dedicated coordination commands
- test coverage for metadata schema

### Risk 3: UX ships before the product model is stable

Mitigation:

- finish Phases 1 and 2 before building a broad UI surface

### Risk 4: Billing complexity slows the core product

Mitigation:

- keep Free tier strong
- defer advanced monetization until the coordination workflow is solid

## Release Gates For MVP

The product MVP is ready for beta when:

1. Coordination commands are implemented and tested.
2. Metadata standards are enforced in code.
3. Coordination store defaults are automatic.
4. Recent activity and blocker queries are usable from CLI and visible in the UI.
5. Fresh-machine install and setup are documented and verified.
6. Pricing, licensing, and activation are defined.

## Immediate Next Step

Start with Phase 1 and Phase 2.

That means:

1. formalize metadata helpers and schema
2. add coordination store path defaults
3. implement coordination commands
4. implement feed and blocker queries

Until those exist, the UX and billing layers are premature.

---
title: Type-System Hardening Candidates 01–04
version: 1.0
date_created: 2026-08-23
owner: chriskarani
tags: [architecture, type-system, wire-compat]
---

# Introduction

Execute the four Strong candidates from the type-system review report
(`swift-type-system-review-Wax-20260823-200449.html`, evidence at 572b7865b):
close three weakly-typed vocabularies at wire/persistence edges and collapse the
CLI's duplicated render path. Must not duplicate open PRs #151–#154.

## 1. Purpose & Scope

Replace runtime ambiguity (silent nil payload access, throw-on-parse composite
strings, Bool×3 lane flags, stringly `FrameMeta.kind`) with compiler-checked
types. Scope: package-internal Wax/Broker, WaxCLI adapter, WaxCore FileFormat,
and kind-comparison sites. Audience: implementer/reviewer subagents.

## 2. Definitions

- **Horizon**: recall lane `working | episodic | durable` (`LayeredRecall.Horizon`).
- **Memory reference**: opaque client-facing `memory_id` string encoding
  horizon + optional session UUID + frame ID.
- **FrameKind vocabulary**: values written into `FrameMeta.kind` —
  `"surrogate"`, `"handoff"`, `PhotoFrameKind` rawValues, `VideoFrameKind` rawValues.
- **Gated command**: CLI command with broker/direct dual paths
  (`shouldUseBroker`) — recall, search, stats, remember.

## 3. Requirements, Constraints & Guidelines

- **REQ-001**: Wire formats are byte-compatible before/after every ticket. Wire keys, defaults, and value encodings do not change.
- **REQ-002**: Persistence bytes (`.wax` frames, `FrameMeta.kind` storage) are unchanged.
- **REQ-003**: No public API changes. `Resources/skills/public/wax/references/public-api.md` gains no entries (all four candidates are package-internal).
- **REQ-004**: Every behavior change ships with a failing-first or characterization test proving it.
- **CON-001**: Swift tools 6.1; StrictConcurrency everywhere; no `-DGRDBCUSTOMSQLITY`/custom sqlite defines.
- **CON-002**: Verification uses targeted suites only: `swift test --filter <Case>`; never unfiltered `swift test`. Do not run benches.
- **CON-003**: New macOS-only test files must be appended to `waxIntegrationLinuxExcludes` in `Package.swift`; prefer placing tests in targets that already build on Linux when practical.
- **CON-004**: No new public protocols/generics beyond what each ticket names. No associatedtype machinery (rejected during review).
- **GUD-001**: Prefer smallest diff; match existing style; no comments unless required by repo convention.
- **PAT-001**: Decode/validation belongs at the declared single boundary (`BrokerCommand.decode` / explicit parse edge), not in handlers.

## 4. Interfaces & Data Contracts

```swift
// T1 — package-internal, Sources/Wax/Broker/
struct HorizonSet: OptionSet, Sendable, Hashable {
    let rawValue: UInt8                       // bit0 working, bit1 episodic, bit2 durable
    static let working, episodic, durable: HorizonSet
    static let all: HorizonSet                // [.working, .episodic, .durable]
}
// BrokerCommand.MemorySearch decode: bools -> HorizonSet; empty set -> typed decode error
// SearchRequest.horizons: HorizonSet replaces includeWorking/includeEpisodic/includeDurable

// T2 — package-internal, Sources/Wax/Broker/
struct MemoryReference: Sendable, Hashable {
    let horizon: LayeredRecall.Horizon        // exact shape pinned by wire grammar survey:
    let sessionID: UUID?                      //   "durable:<frame>" has nil session;
    let frameID: UInt64                       //   "<horizon>:<session>:<frame>" otherwise
    init?(parsing raw: String)                // replaces parseMemoryReference throws
    var wireValue: String                     // replaces makeMemoryReference; byte-identical output
}

// T3 — shared result structs live in Wax/Broker next to BrokerCommand
struct BrokerRecallRow: Sendable {              // decoded from response payload object
    let rank: Int; let kind: String?
    let frameId: UInt64; let score: Double; let text: String
    init(_ payload: [String: AgentBrokerValue]) throws
}   // analogous structs for search rows (+ stats where cheap); missing key => thrown error

// T4 — package-internal, Wax module (NOT WaxCore: PhotoFrameKind/VideoFrameKind live in
//      Wax, and WaxCore cannot import Wax — dependency direction Wax -> WaxCore).
//      WaxCore writer sites (Wax.swift surrogate/handoff literals) stay plain strings
//      aligned by characterization test; they MUST NOT import Wax.
package enum FrameKind: Hashable, Sendable {
    case surrogate, handoff
    case photo(PhotoFrameKind)
    case video(VideoFrameKind)
    case other(String)                        // forward-compat escape hatch
    init(rawKind: String?)                    // single parse point; nil => .other semantics per survey
    var storageValue: String?                 // byte-identical to today's kind strings
}
```

## 5. Acceptance Criteria

- **AC-101** (T1): Given `include_working=false&include_episodic=false&include_durable=false`, decode fails with a named error mentioning lanes; given no flags, selection equals `.all`.
- **AC-102** (T1): The scope-derivation switch (AgentBrokerService.swift:586–604) is expressed as HorizonSet algebra; unit test pins session-scope visibility (working dropped) matches old table exactly.
- **AC-103** (T1): Existing broker memory-search integration tests pass unchanged (same wire requests/results).
- **AC-201** (T2): Round-trip property test: for every horizon/session/frame combination the package produces, `MemoryReference(parsing: ref.wireValue)` returns an equal value; malformed literals throw only at `init(parsing:)`.
- **AC-202** (T2): `grep` shows zero remaining call sites formatting memory IDs via interpolation outside `MemoryReference`.
- **AC-301** (T3): RecallCommand and SearchCommand each contain ONE renderer consuming typed rows; deleting the broker daemon does not remove their direct-path rendering (shared code).
- **AC-302** (T3): Decoder test feeds a payload with a missing key and asserts a thrown named error; typo'd-key scenario compiles as field access (no string lookup left in gated renderers).
- **AC-303** (T3): `brokerPayloadObject/brokerString/brokerInt…` helpers have no callers inside gated commands (forwarding commands exempt).
- **AC-401** (T4): Characterization test asserts every kind string currently written by the package maps through `FrameKind` to identical `storageValue` bytes.
- **AC-402** (T4): All comparison sites listed in the report use `FrameKind` switches; adding a new case produces exhaustiveness diagnostics (verified by temporarily compiling a switch).
- **AC-403** (T4): Unknown stored kinds map to `.other` and survive re-save unchanged.

## 5b. Tickets (task graph)

| id | title | depends-on | exclusive-writes | acceptance | review-hint |
|----|-------|-----------|------------------|------------|-------------|
| T1 | HorizonSet closes lane-selection state space | none | `Sources/Wax/Broker/BrokerCommand.swift`, `Sources/Wax/Broker/AgentBrokerService.swift`, `Sources/Wax/Broker/LayeredRecall.swift`, `Sources/Wax/Broker/HorizonSet.swift` (new), broker tests | AC-101..103 | 101–1499 |
| T2 | MemoryReference newtype for composite memory IDs | T1 | `Sources/Wax/Broker/LayeredRecall.swift`, `Sources/Wax/Broker/AgentBrokerService.swift`, `Sources/Wax/Broker/AgentBrokerService+Markdown.swift`, `Sources/Wax/Broker/MemoryReference.swift` (new) | AC-201..202 | 101–1499 |
| T3 | Typed broker client responses collapse CLI dual renderers | T2 | `Sources/Wax/Broker/` (response row structs, `AgentBrokerClient.swift`), `Sources/WaxCLI/RecallCommand.swift`, `SearchCommand.swift`, `RememberCommand.swift`, `StatsCommand.swift`, `BrokerCLIHelpers.swift`, CLI tests | AC-301..303 | 101–1499 |
| T4 | FrameKind enum closes FrameMeta.kind vocabulary | none (parallel) | `Sources/Wax/FrameKind.swift` (new), kind-comparison sites in `Wax/PhotoRAG/PhotoRAGOrchestrator.swift`, `Wax/VideoRAG/VideoRAGOrchestrator.swift`, `Wax/UnifiedSearch/UnifiedSearch.swift`, `Wax/Orchestrator/MemoryOrchestrator.swift`, `Wax/Orchestrator/MemoryOrchestrator+Maintenance.swift`, Wax-module tests. WaxCore `FrameMeta.kind` storage untouched; WaxCore writer literals may only be touched if a constant lives in WaxCore itself | AC-401..403 | ≥1500 likely |

Frontier at start: T1 ∥ T4.

## 6. Test Automation Strategy

- Frameworks: swift-testing (`@Test`), matching existing suite style.
- Levels: unit tests adjacent to new types; integration via existing broker/CLI suites; no new e2e harness.
- Data: reuse `Tests/*/Fixtures`; construct in-memory sessions where suites already do.
- CI: targeted filters locally; GitHub Actions runs its standard matrix post-merge.
- Commands: `swift test --filter <TestSuite>` scoped to touched suites (discover exact names via `rg -l "include_working|parseMemoryReference|layeredMemorySearch|FrameMeta" Tests`).

## 7. Rationale & Context

Report candidates 01–04 (Strong); top recommendation 03-in-report = T3 here.
Rejected alternatives and evidence line numbers are recorded in the HTML report;
do not reopen them without new evidence. Serialized T1→T2→T3 because they share
exclusive write paths in `Sources/Wax/Broker/`.

## 8. Dependencies & External Integrations

No external system changes. Socket wire protocol and `.wax` format are frozen contracts (DAT-001). MCP server untouched (EXT-001 observes same wire).

## 9. Examples & Edge Cases

See §4 code contracts; empty-set rejection (AC-101), unknown-kind survival (AC-403), missing-payload-key error (AC-302).

## 10. Validation Criteria

Per-ticket targeted suites green on the ticket branch; wire-format characterization tests added under REQ-004; `git diff` limited to the ticket's exclusive-writes.

## 11. Related Specifications / Further Reading

- Report: `${TMPDIR}/swift-type-system-review-Wax-20260823-200449.html`
- Open stack this must not conflict with: PRs #151–#154 (arch/0b27937a/*)

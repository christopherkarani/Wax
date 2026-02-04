# PhotoRAG Fixes — Immutable Plan

## Goals
- Support time-only and location-only queries by enabling timeline fallback for constraint-only queries.
- Correctly handle radius <= 0 in location filtering to avoid false positives/empty results.
- Deduplicate assetIDs during ingest while preserving original order.
- Implement changes test-first using Swift Testing.

## Constraints
- Use `SearchRequest.allowTimelineFallback` for constraint-only queries (time and/or location with no text).
- Location allowlist: return `nil` for invalid radius (<= 0) to avoid filtering everything.
- Dedupe must be stable (preserve first occurrence order).
- Maintain Swift 6.2 type safety and minimal public surface change.
- Tests must be written first and must fail before implementation.

## Non-Goals
- No ranking/reranking algorithm changes.
- No schema or persistence format changes.
- No new public API endpoints beyond existing request fields.
- No performance optimization beyond correctness.

## Architecture Decisions
- Constraint-only query detection: `(text.isEmpty && (hasTime || hasLocation))` → set `allowTimelineFallback = true`.
- Radius <= 0 handling: return `nil` allowlist (skip location filtering).
- Stable dedupe for ingest: ordered set pattern (membership set + ordered list).

## Detailed To-Do List
### Phase 1 — Context & Scoping
1. Locate SearchRequest construction and query parsing.
2. Identify location allowlist computation and radius usage.
3. Find ingest pipeline where assetIDs are collected/normalized.
4. Map existing tests and Swift Testing usage.

### Phase 2 — Planning Tests
1. Define behavioral test cases:
   - Time-only query triggers timeline fallback.
   - Location-only query triggers timeline fallback.
   - Location radius <= 0 results in nil allowlist.
   - Dedupe assetIDs preserves first-seen order.
2. Decide minimal test harness wiring.

### Phase 3 — Test-First Implementation
1. Add Swift Testing cases for timeline fallback constraints.
2. Add tests for radius <= 0 allowlist semantics.
3. Add tests for stable dedupe in ingest.
4. Ensure tests fail with current behavior.

### Phase 4 — Core Fixes
1. Enable allowTimelineFallback for constraint-only queries.
2. Update allowlist logic to return nil for radius <= 0.
3. Implement stable dedupe in ingest (no reordering).

### Phase 5 — Review & Validation
1. Verify plan compliance and API safety.
2. Review for correctness, Sendable safety, misuse resistance.
3. Confirm tests pass and cover edge cases.

### Phase 6 — Gap Resolution
1. Address review findings and failing tests.
2. Re-run reviews if changes are substantive.

### Phase 7 — Final System Review
1. Holistic check for architecture coherence and docs.
2. Confirm non-goals were exceeded.

## Task → Agent Mapping
### Context Gathering
- Context/Research Agent: locate code paths for query parsing, allowlist, ingest, tests.

### Planning
- Planning Agent: design test matrix + minimal harness changes.

### Tests (TDD)
- Implementation Agent A: timeline fallback tests.
- Implementation Agent B: radius <= 0 allowlist tests.
- Implementation Agent C: stable dedupe ingest tests.

### Implementation
- Implementation Agent A: constraint-only query logic.
- Implementation Agent B: location allowlist radius <= 0 behavior.
- Implementation Agent C: stable dedupe in ingest.

### Review
- Code Review Agent 1: plan compliance + API correctness.
- Code Review Agent 2: concurrency/type safety + misuse resistance.

### Gap Resolution
- Fix/Gap Agent: address review findings and re-verify.

### Final Review
- Holistic Review Agent: architecture + tests + docs.

---
name: swift-front-api-rater
description: >
  Rate the quality of a Swift framework's front-facing public API using a deterministic 0-100 rubric
  focused on dual DX (humans + coding agents), power/extensibility retention, concise naming, and
  elegant Swift 6.2 composition. Includes integrated Swift Concurrency Expert checks for actor isolation,
  Sendable safety, and concurrency compliance. Use when asked to score, benchmark, or compare API quality before/after redesigns.
---

# Swift Front API Rater

Use this skill to produce a rigorous score for the public API of any Swift package or framework.

## Primary goals

- Score API quality with repeatable metrics.
- Protect high DX for both humans and coding agents.
- Ensure API slimming does not reduce power or extensibility.
- Enforce concise, intuitive naming.
- Reward elegant use of advanced Swift 6.2 language features.
- Verify concurrency safety and Swift 6.2 concurrency correctness as part of API quality.

## Inputs

1. Public API snapshot (symbols and signatures).
2. Key usage flows (at least 3, ideally 5).
3. Before/after context if comparing redesigns.

## Scoring model (0-100)

### Category weights

- Human DX: 18 points
- Agent DX: 18 points
- Naming Quality: 14 points
- Surface Efficiency: 8 points
- Power & Extensibility: 17 points
- Swift 6.2 Composition Elegance: 10 points
- Concurrency Safety & Compliance: 10 points
- Error + Migration Quality: 5 points

### Hard quality gates

- Human DX must be `>= 4.5/5`.
- Agent DX must be `>= 4.5/5`.
- Power & Extensibility must be `>= 4.5/5`.
- Naming Quality must be `>= 4.5/5`.
- Concurrency Safety & Compliance must be `>= 4.5/5`.
- Any gate failure marks outcome as `Not Release Ready` regardless of total.

## Metric definitions

### 1) Human DX (0-20)

Rate 1-5, then convert: `score = rating / 5 * 18`.

- Discoverability from autocomplete.
- Readability of call sites.
- Quality of defaults.
- Predictability across API families.
- Documentation dependency for common tasks.

### 2) Agent DX (0-20)

Rate 1-5, then convert: `score = rating / 5 * 18`.

- First-try correctness from names/signatures.
- Low overload ambiguity.
- Deterministic parameter labeling.
- Minimal hidden prerequisites.
- Stable pattern reuse across endpoints.

### 3) Naming Quality (0-15)

Rate 1-5, then convert: `score = rating / 5 * 14`.

- Canonical noun/verb set.
- No synonym duplication (`Config` + `Configuration`, `Result` + `SearchResults`).
- Short, specific, durable names.
- Consistent action verbs across operations.

### 4) Surface Efficiency (0-10)

Rate 1-5, then convert: `score = rating / 5 * 8`.

- Public type/member count proportional to feature set.
- Low overlap/redundancy.
- Supporting types nested under root domains where appropriate.

### 5) Power & Extensibility (0-20)

Rate 1-5, then convert: `score = rating / 5 * 17`.

- Strategy injection points exist where needed.
- Protocol/generic seams support custom implementations.
- Feature parity retained after simplification.
- No forced forking for common advanced needs.

### 6) Swift 6.2 Composition Elegance (0-10)

Rate 1-5, then convert: `score = rating / 5 * 10`.

- Generics used to collapse duplicate APIs.
- Protocol composition used instead of wrapper-type bloat.
- Correct `some`/`any` boundaries.
- Typed closures used for focused customization.
- Result builders or parameter packs used only when they reduce real complexity.
- Macros used only with major measurable benefit.

### 7) Concurrency Safety & Compliance (0-10)

Rate 1-5, then convert: `score = rating / 5 * 10`.

- Public API actor isolation is explicit and coherent (`@MainActor`, actors, `nonisolated` boundaries).
- No unsafe cross-actor public API calls in common usage flows.
- Publicly exposed types used across concurrency domains are properly `Sendable` (or intentionally constrained).
- No unnecessary `@unchecked Sendable` in public-facing abstractions.
- Concurrency model is predictable for both humans and coding agents.

### 8) Error + Migration Quality (0-5)

Rate 1-5, then convert: `score = rating / 5 * 5`.

- Domain-canonical error surface.
- Clear migration path and deprecations.
- Before/after examples for top flows.

## Penalties

Apply after category scoring.

- `-3` each synonym pair in public API naming (max `-12`)
- `-2` each ambiguous overload cluster (max `-10`)
- `-3` each leaked internal/plumbing type in public signature (max `-12`)
- `-5` if no migration guidance for a breaking redesign
- `-3` each unresolved public concurrency hazard (actor isolation, sendability, data-race risk) (max `-15`)

Final score: `max(0, min(100, weighted_total - penalties))`.

## Procedure

1. Build public API inventory.
2. Run concurrency review lane using the `swift-concurrency-expert` methodology.
3. Score each category with explicit evidence.
4. Apply penalties.
5. Evaluate hard gates.
6. Produce prioritized fix list tied to metric losses.
7. Re-rate after changes using identical rubric.

## Output format

### Front-Facing API Rating Report

- Overall Score: `NN/100`
- Release Readiness: `Ready` or `Not Release Ready`
- Gate Status:
  - Human DX: `x.x/5`
  - Agent DX: `x.x/5`
  - Power & Extensibility: `x.x/5`
  - Naming Quality: `x.x/5`
  - Concurrency Safety & Compliance: `x.x/5`

### Category Breakdown

- Human DX: `NN/18`
- Agent DX: `NN/18`
- Naming Quality: `NN/14`
- Surface Efficiency: `NN/8`
- Power & Extensibility: `NN/17`
- Swift 6.2 Composition Elegance: `NN/10`
- Concurrency Safety & Compliance: `NN/10`
- Error + Migration Quality: `NN/5`
- Penalties: `-NN`

### Top Findings

1. Highest-severity gap.
2. Next high-impact gap.
3. Next high-impact gap.

### Targeted Fixes

1. Fix with expected score gain.
2. Fix with expected score gain.
3. Fix with expected score gain.

## Interpretation bands

- `90-100`: Exceptional. Small polish only.
- `80-89`: Strong. Address targeted friction.
- `70-79`: Usable but inconsistent. Requires focused redesign.
- `60-69`: Significant API quality debt.
- `<60`: Major redesign required.

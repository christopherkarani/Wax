---
name: swift-api-surface-minimizer
description: >
  Shrink and modernize a Swift public API by 60-90% without losing capability. Use when you need to
  reduce type/member count, improve naming, consolidate overlapping APIs with Swift 6.2 generics and
  protocols, apply `some`/`any` correctly, introduce closure-first ergonomics, and preserve top-tier DX
  for both coding agents and humans while maximizing extensibility.
---

# Swift API Surface Minimizer

Use this skill when a framework API feels too large, repetitive, or ambiguous.

## Outcomes

- One obvious public entry point per domain capability.
- Fewer public types, fewer overloads, fewer names to memorize.
- Equal or greater capability through composition.
- Better autocomplete outcomes for agents and humans.
- Concise, intuitive, stable naming with minimal synonym noise.
- High extensibility through protocol/generic seams instead of public type sprawl.

## Non-negotiable constraints

- Do not remove power.
- Do not hide essential behavior behind magic.
- Do not introduce macros unless the payoff is substantial and measurable.
- Keep migration practical with deprecations and compatibility aliases when needed.
- Keep both audiences first-class: agent first-try correctness and human readability must both stay high.

## Phase 1: Inventory and baseline

1. Enumerate every `public` and `open` symbol.
2. Group symbols into: entry points, config/options, protocols, data carriers, errors, helpers.
3. Count baseline surface:
   - Public types
   - Public methods/inits/subscripts
   - Distinct nouns in type names
   - Distinct verbs in method names
4. Capture 5 common user flows and the APIs they touch.

## Phase 2: Keep/merge/remove decisions

Apply this decision order to each public symbol.

1. Keep if it is a primary user action and uniquely valuable.
2. Merge if another symbol does the same job with small shape differences.
3. Demote to `internal`/`package` if it is plumbing.
4. Remove if fully redundant and migration cost is low.

## Phase 3: Naming audit and canonical vocabulary

Choose one canonical noun and one canonical verb per concept.

- Prefer one root noun per domain, for example `Memory`, `Store`, `Agent`, `Pipeline`.
- Ban synonym pairs in public surface, for example `Config` plus `Configuration`, `Result` plus `SearchResult`.
- Keep verbs task-oriented and short, for example `save`, `search`, `load`, `flush`.
- Move technical detail terms behind options/protocols unless directly user-facing.

## Phase 4: Swift 6.2 surface-minimization toolbox

Use these features in this order.

1. Generics
   - Collapse parallel APIs into one generic API.
   - Prefer constrained generics over duplicated concrete variants.
2. Protocols
   - Use protocols for capability seams, not for every model type.
   - Keep protocols small and behavioral.
3. `some` and `any`
   - Return `some Protocol` to hide implementation and reduce type leakage.
   - Accept generic `some Protocol` parameters for static dispatch and clarity.
   - Use `any Protocol` only for heterogenous storage boundaries.
4. Closures
   - Prefer closure-based customization over overload explosion.
   - Use typed closures to inject strategy behavior with minimal API growth.
   - Use closure typealiases when they improve readability and cut public type count.
5. Protocol composition and enum composition
   - Use `some P & Q` or generic constraints instead of creating many tiny wrapper protocols.
   - Use enums with associated values to unify mode/strategy families.
6. Result builders
   - Use for compositional declarations that otherwise require verbose arrays or chained `.add(...)`.
7. Parameter packs
   - Use for typed variadics when many overloads only differ by arity.
8. Macros
   - Use only when they remove large repeated API or large repeated conformance boilerplate.
   - Avoid if normal generic/protocol design already solves it cleanly.

## Phase 5: API shape patterns

### Pattern A: Overload matrix to options + closure

```swift
// Before
public func search(_ query: String) async throws -> SearchResults
public func search(_ query: String, topK: Int) async throws -> SearchResults
public func search(_ query: String, filters: [String: String]) async throws -> SearchResults

// After
public struct SearchOptions: Sendable {
    public var topK: Int = 8
    public var filters: [String: String] = [:]
    public init() {}
}

public func search(
    _ query: String,
    options: SearchOptions = .init(),
    rerank: (@Sendable ([Hit]) async throws -> [Hit])? = nil
) async throws -> SearchResults
```

### Pattern B: Duplicate types to generic core

```swift
// Before
public struct InputRule { ... }
public struct OutputRule { ... }

// After
public protocol RulePhase: Sendable {}
public enum InputPhase: RulePhase {}
public enum OutputPhase: RulePhase {}

public struct Rule<Phase: RulePhase>: Sendable { ... }
```

### Pattern C: Type leakage to opaque return

```swift
// Before
public func observed(by observer: LoggerObserver) -> LoggingMemory

// After
public func observed(by observer: some Observer) -> some MemoryRuntime
```

### Pattern D: Sibling top-level types to nested names

```swift
// Before
public struct MemoryConfig { ... }
public struct MemorySearchOptions { ... }
public struct MemorySaveOptions { ... }

// After
public enum Memory {
    public struct Config { ... }
    public struct SearchOptions { ... }
    public struct SaveOptions { ... }
}
```

## Phase 6: Error model cleanup

- Expose one domain-canonical error type, for example `Memory.Error`.
- Keep engine-internal errors mapped into canonical cases.
- Preserve original error as associated value when needed for diagnostics.

## Phase 7: Agent + human DX scoring

Score the redesigned API before shipping.

- Human DX (1-5): discoverability, readability, naming clarity, default ergonomics.
- Agent DX (1-5): first-try correctness from signature + names, overload ambiguity, call-site determinism.
- Combined score: `(human + agent) / 2`.
- Release gate: `human >= 4.5`, `agent >= 4.5`, and no major category below `4.0`.

Ship only if combined score improves and capability is preserved.

## Phase 8: Migration strategy

1. Keep old entry points as deprecated wrappers for one cycle when feasible.
2. Emit clear rename messages in deprecations.
3. Publish side-by-side before/after examples.
4. Remove deprecated shims after adoption target is met.

## Naming rubric checklist

- One canonical noun per domain.
- One canonical options container per operation family.
- No suffix clutter unless it carries unique semantic meaning.
- Verb labels are action-first and unambiguous.
- Labels optimize autocomplete ranking for likely user intent.

## Minimum deliverables

1. API catalog snapshot before and after.
2. Public-surface reduction percentage.
3. List of removed or demoted symbols with rationale.
4. New canonical naming map.
5. Migration snippets for top user flows.
6. DX scorecard with explicit agent and human scores.

## Anti-patterns to reject

- Creating multiple facade types with near-identical method sets.
- Publishing plumbing protocols that users never conform to.
- Using `any` broadly when static generic dispatch is possible.
- Macro-first design where language features alone suffice.
- Introducing parallel `Config` or `Result` families that differ only by name.

## Quick execution template

1. Baseline counts and catalog.
2. Canonical vocabulary decision.
3. Consolidate with generics/protocol seams.
4. Collapse overloads into options plus closures.
5. Hide concrete internals with `some`.
6. Nest supporting types under primary root.
7. Normalize errors under domain type.
8. Publish examples and migration map.

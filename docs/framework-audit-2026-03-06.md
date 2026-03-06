# Wax Framework Audit — 2026-03-06

## 1. Framework Summary

- **Purpose:** On-device long-term memory engine for AI agents with ingestion, hybrid retrieval, and RAG context assembly.
- **Swift/tooling target:** Swift 6.2 API messaging; package manifest currently uses `swift-tools-version: 6.1` and strict concurrency experimental flag per target.
- **Platforms (manifest truth):** iOS 18+, macOS 15+.
- **Dependencies:** USearch, GRDB.swift, swift-testing, swift-log, MCP swift-sdk, swift-argument-parser, swift-crypto, swift-docc-plugin, SwiftTUI, Noora.
- **Public API surface (source scan):** ~1,571 public/open declarations across packages (`Wax`: 781, `WaxCore`: 608, `WaxTextSearch`: 22, `WaxVectorSearch`: 76, `WaxVectorSearchMiniLM`: 84).
- **Overall health score:** **8.0/10**.

**First impression:** Wax has strong architecture depth, broad tests, and ambitious multimodal ergonomics. Primary risks are API surface sprawl, documentation drift vs manifest truth, and pockets of unsafe optional/force-unwrapped behavior in hot code paths and generated model wrappers.

---

## 2. Bug Report

| Severity | File | Line | Bug | Fix Applied |
|----------|------|------|-----|-------------|
| High | `README.md` | Requirements/License sections | Declared platform minimums and license metadata were inconsistent with package/licensing source of truth. | ✅ Updated README platform minimums to iOS 18/macOS 15 and license to Apache 2.0. |
| Medium | `README.md` | Contributing section | README pointed to contribution flow but repo lacked a contribution guide. | ✅ Added `CONTRIBUTING.md` and linked it in README. |
| Medium | `Sources/WaxVectorSearch/MetalVectorEngine.swift` | 497 | Force-unwrap of optional pipeline in performance path (`computePipelineSIMD8!`). | ⚠️ Identified; not yet patched in this pass (requires targeted behavior/perf regression checks). |
| Medium | `Sources/WaxTextSearch/FTS5SearchEngine.swift` | 223, 226 | Optional force-unwrapping in validation guard paths (`toMs!`). | ⚠️ Identified; recommended safe binding migration. |
| Low | `Sources/WaxCore/BinaryCodec/BinaryDecoder.swift` | 139-144 | Multiple `as!` casts in generic decode helper. | ⚠️ Identified; likely safe by type guard but should migrate to constrained overloads for stronger compile-time safety. |

---

## 3. Type System Improvements

1. **Before:** Generic decode method uses runtime type checks + forced casts.
   - **After:** Add constrained overloads for primitives and remove `as!` branches.
   - **Why:** Improves static safety and reduces runtime trap risk.
   - **Breaking:** No (if overloads are additive and old path deprecated).

2. **Before:** Several APIs return optionals on recoverable internal errors.
   - **After:** Add `async throws` variants and deprecate optional-return wrappers via `@available(*, deprecated, renamed:)`.
   - **Why:** Avoid silent failure modes; better contracts for app + agent consumers.
   - **Breaking:** No (with staged deprecation path).

3. **Before:** Large public API spread with multiple overlapping entry paths.
   - **After:** Consolidate to one preferred path per top use case in docs + deprecate duplicates.
   - **Why:** Better human and AI disambiguation.
   - **Breaking:** No (if deprecation-guided).

---

## 4. Naming Changes

| Current Name | Proposed Name | Reason | Breaking |
|--------------|---------------|--------|---------|
| `openMiniLM` | `open(miniLMAt:)` | Better call-site readability + consistent “open” family shape. | Yes (unless added as overload + deprecate old). |
| `remember(_ content:)` | `remember(text:)` | Explicit label helps AI agents infer argument role. | Yes (unless overload + deprecate old). |
| `recall(query:)` | `context(for:)` | Return type is context object, not arbitrary recall side effect. | Yes (unless overload + deprecate old). |

---

## 5. Namespace Audit

- Public API breadth is high; consider nested namespacing for domain-specific utility types under parent orchestrators.
- Audit all public stdlib/Foundation extensions for scope pollution; move generic helpers to `internal` unless Wax-specific.
- Avoid broad utility naming in public scope (`Helpers`, `Utils`, `Manager`-style patterns) to improve autocomplete precision for human/AI users.

---

## 6. API Ergonomics Report

- **Human developer ergonomics:** 8/10.
- **AI coding agent ergonomics:** 7/10.

Top friction points:
1. Very large public surface with overlapping routes for similar goals.
2. Optional-return APIs that hide root cause details.
3. Inconsistent naming verbs across retrieval-oriented APIs.
4. Documentation drift (requirements/license) can induce bad generated setup code.
5. Some public declarations still under-documented relative to “contract-first” expectations.

---

## 7. Concurrency Report

Key findings:
- Strict concurrency intent is strong (`StrictConcurrency` enabled), but there are still legacy lock-based caches and runtime optional/cast traps in concurrent code paths that can undermine reliability.
- Prefer actor-backed caches where mutation crosses async boundaries.
- Replace silent `try?` in critical async model execution paths with explicit throwing paths.
- Generated CoreML wrappers are expected to include force unwraps; isolate with safe adapter boundaries and public typed errors.

---

## 8. README Rewrite

A complete README rewrite has been applied in `README.md` to align with:
- Accurate platform + license metadata.
- Immediate quick-start example.
- Installation + capability narrative.
- “When to use / when not to use”.
- Contributing link and clearer documentation navigation.

---

## 9. New & Improved Tests

No new tests were added in this docs-focused audit pass.

Recommended next TDD tranche:
1. Add regression tests for each remaining force-unwrap site listed in section 2.
2. Add tests asserting throwing error contracts for embedding encode APIs.
3. Add doc-driven smoke tests to compile every README snippet under CI.

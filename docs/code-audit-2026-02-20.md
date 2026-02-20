# Wax Deep Code Review & Production Readiness Audit (2026-02-20)

## Scope

- Full repository static review across `Sources/`, `Tests/`, `scripts/`, package manifests, and docs.
- Build/test gate execution on this environment.
- Focus areas: correctness, reliability, perf scalability, security/compliance, and operational readiness.

## Methodology

1. Repository-wide static inspection (`rg`, direct source reads, and quality scripts).
2. Execution of test/build gates to verify real behavior rather than speculative findings.
3. Triage pass to remove false positives and keep only evidence-backed findings.

### Commands Executed

```bash
swift test --parallel
bash scripts/quality/production_readiness_gates.sh
bash -x scripts/quality/check_corruption_assertions.sh
swift test --filter WaxCoreTests --parallel
rg -n "TODO|FIXME|fatalError\(|preconditionFailure\(|try!|as!|force unwrap|URLSession\.shared" Sources Tests scripts Package.swift
```

## Validated Findings (Post False-Positive Review)

## 1) Build/Gate Breakage on Current Linux CI-like Environment (High)

### Evidence

- `swift test --parallel` fails while compiling the transitive dependency `SwiftTiktoken` (`URLSession.shared` missing on Linux toolchain in this environment).
- `scripts/quality/production_readiness_gates.sh` also fails for the same reason before gates can complete.
- The package advertises Apple platforms only (`.iOS(.v26)`, `.macOS(.v26)`), but the gate script runs unconditionally and currently does not short-circuit for non-supported platforms.

### Impact

- Production-readiness gates are currently not executable in this environment.
- CI signal is noisy/blocked if Linux runners are used or accidentally selected.

### Recommendations

- Add explicit platform guardrails in quality scripts (fail fast with clear message or skip with rationale on unsupported platforms).
- Optionally pin/patch `swift-tiktoken` for Linux compatibility if Linux CI is intended.
- Add a dedicated CI matrix policy: Apple runners for full gates; optional Linux smoke scope with supported target subset only.

---

## 2) False-Negative Risk in Corruption Assertion Gate Script (High)

### Evidence

- `scripts/quality/check_corruption_assertions.sh` checks corruption coverage with:
  - `rg -n "@Test.*(corrupt|truncat)" Tests/WaxCoreTests/ProductionReadinessRecoveryTests.swift`
- In the test file, `@Test` and function names are on separate lines (standard style), so the regex returns `0` and the gate fails even though corruption/truncation tests exist.

### Impact

- Gate reports missing corruption coverage when coverage exists.
- Increases engineering friction and can hide real regressions behind script noise.

### Recommendations

- Update script to detect function name on following line(s), e.g. parse test declarations structurally or use multiline patterns.
- Add a script self-test fixture to prevent future regex regressions.

---

## 3) Contention-Path Queue Data Structure Bottleneck (`removeFirst`) (Medium)

### Evidence

- FIFO waiter queues in hot contention paths use `Array.removeFirst()`, which is O(n):
  - `Sources/WaxCore/Concurrency/AsyncMutex.swift`
  - `Sources/WaxCore/Concurrency/ReadWriteLock.swift` (async waiter arrays)
  - `Sources/WaxCore/Wax.swift` (writer lease waiters)

### Impact

- Under high writer/reader contention, dequeue operations can add avoidable CPU and latency overhead due to repeated array shifting.

### Recommendations

- Replace FIFO arrays with an amortized O(1) queue (ring-buffer/deque abstraction).
- Add contention microbenchmarks (high waiter counts) and track p95/p99 lock acquisition latency.

---

## 4) Production License Enforcement Gap in MCP Server (Medium)

### Evidence

- `Sources/WaxMCPServer/LicenseValidator.swift` explicitly states:
  - Validation is format-only client-side.
  - Activation ping is currently a no-op placeholder (`pingActivation`).
- Any key matching pattern format currently passes local validation.

### Impact

- Commercial/license-control policy is not enforceable in production as-is.
- Potential compliance and revenue-protection risk.

### Recommendations

- Implement signed token or server-verified activation flow.
- Add offline grace policy + cryptographic signature verification.
- Add negative tests for forged format-valid keys.

---

## 5) Product Surface/Schema Mismatch for MCP Photo Tools (Low/Medium)

### Evidence

- `Sources/WaxMCPServer/ToolSchemas.swift` marks photo tool schemas as permissive stubs and notes they return `isError:true` until Soju integration is complete.

### Impact

- Tool discoverability suggests availability, but behavior is intentionally stubbed.
- Client UX and observability can degrade if callers assume full implementation.

### Recommendations

- Mark tools with explicit capability/version metadata.
- Optionally hide unimplemented tools behind trait/feature flag unless enabled.

## False Positives & Hallucination Review

The following were explicitly **excluded** from final findings:

- Use of `fatalError`/`precondition` in low-level lock internals was not automatically classified as a bug; these can be intentional fail-fast invariants.
- `try!` usage identified in tests was not treated as production defect.
- Platform mismatch alone was not treated as core library defect because `Package.swift` clearly targets Apple platforms.

Only findings with direct code/runtime evidence and real-world impact were retained.

## Prioritized Remediation Plan

1. **Unblock gates**: platform-aware gate scripts + CI matrix clarity.
2. **Fix corruption gate regex** to eliminate false failures.
3. **Queue structure optimization** for contention hot paths.
4. **Ship real license validation** before production enforcement.
5. **Align MCP tool exposure with implementation readiness**.

## Production Readiness Exit Criteria (Suggested)

- Gates pass on intended platform runners with zero false negatives.
- Corruption/recovery gate script validated by self-tests.
- Contention benchmark shows no O(n) dequeue amplification at high waiter counts.
- MCP license path enforces authenticity (not format-only).
- Stub tools either hidden or explicitly capability-gated.

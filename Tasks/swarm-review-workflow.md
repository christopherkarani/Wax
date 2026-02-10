# Comprehensive Code Review - Wax `<branch-name>` Branch

## Context

The `<branch-name>` branch introduces changes to the Wax on-device RAG framework. Run `git diff main --stat` and `git diff main --name-only` to identify all changed files, then categorize them by module (PhotoRAG, VideoRAG, RAG, WaxCore, MiniLM, Tests, etc.).

## Swarm Architecture

**3 phases**, up to 8 total agents. Phase 1 runs up to 6 agents in parallel (review + perf + test coverage + docs). Phase 2 runs a judge agent. Phase 3 applies fixes via parallel fix agents + a verification judge.

```
Phase 1: Parallel Analysis (up to 6 agents simultaneously)
+------------------------------------------------------------------+
|  +------+ +------+ +------+ +------+ +------+ +------+          |
|  | R1   | | R2   | | R3   | |  P1  | |  T1  | |  D1  |          |
|  |Module| |Module| |Module| | Perf | | Test | | Docs |          |
|  |Review| |Review| |Review| |Audit | |Cover | |Audit |          |
|  +------+ +------+ +------+ +------+ +------+ +------+          |
|  swift-code-reviewer (3)     code-    general  general           |
|                              explorer purpose  purpose           |
+------------------------------------------------------------------+
                              |
                              v
Phase 2: Quality Gate (1 judge agent)
+------------------------------------------------------------------+
|                        +--------+                                |
|                        | JUDGE  |                                |
|                        | Cross- |                                |
|                        | review |                                |
|                        +--------+                                |
|                        general-purpose                           |
+------------------------------------------------------------------+
                              |
                              v
Phase 3: Fix & Verify (N fix agents + 1 judge)
+------------------------------------------------------------------+
|  Fix agents run in parallel (fixer/implementer by complexity)    |
|  Judge verifies all fixes + runs swift build                     |
+------------------------------------------------------------------+
```

---

## Phase 1: Review Agent Assignments

### Reviewer Agents (R1, R2, R3): `swift-code-reviewer`

Split changed source files across up to 3 reviewer agents by module. Each reviewer gets ~5-10 files. Assign the largest/most complex file as PRIMARY FOCUS.

**Review focus for ALL reviewers:**
- Actor isolation correctness, `@Sendable` conformances
- Cross-actor coordination and reentrancy risks
- `nonisolated(unsafe)` usage - verify thread safety
- `withCheckedThrowingContinuation` / `withCheckedContinuation` - verify single-resume
- Error handling - silent `try?` swallowing, missing error paths
- Memory management - retain cycles, unbounded collections
- Token budget compliance and truncation logic
- API design consistency

**Output format per reviewer:**
For each finding: Severity (CRITICAL/HIGH/MEDIUM/LOW), Category (security|correctness|concurrency|performance|style), File:line reference, Description, Suggested fix. Group by file, then severity. End with summary count.

### Performance Agent (P1): `feature-dev:code-explorer`

Scope: ALL changed source files. Analyze:
1. **Ingest throughput** - count actor hops, disk I/O calls, suspension points per item
2. **Recall/query latency** - trace actor hop chains end-to-end
3. **Batch efficiency** - batch vs per-item thresholds
4. **Blocking I/O** - synchronous calls in async contexts
5. **Memory pressure** - peak memory estimates at scale
6. **Redundant work** - cacheable computations re-done
7. **O(N) scans** - linear scans that should use indexes
8. **N+1 patterns** - lazy paths triggering per-item actor hops
9. **Allocation hot paths** - string concatenation, arrays without reserveCapacity
10. **ANE/GPU scheduling** - CoreML compute unit scenarios

**Output:** Ranked bottlenecks by severity (BLOCKING > O(N) SCALING > ALLOCATION > CONTENTION) with file:line references and impact estimates.

### Test Coverage Agent (T1): `general-purpose`

Scope: ALL test files + ALL source files.
1. **Audit coverage** - map every public API method to its test(s), identify gaps
2. **Identify gaps** - missing edge cases, concurrency tests, error paths, integration tests
3. **Fix anti-patterns** - replace `#expect(Bool(false))` with `Issue.record()`, remove unnecessary error wrappers, extract shared helpers
4. **Write new tests** for highest-priority gaps

### Documentation Agent (D1): `general-purpose`

Scope: Entire codebase.
1. **Audit** all CLAUDE.md files, README.md, doc comments on public APIs
2. **Write/update** CLAUDE.md files with module conventions and architecture
3. **Create ADRs** for key design decisions in `docs/adr/`
4. **Add doc comments** to undocumented public types, protocols, and methods

---

## Phase 2: Judge Agent

### Agent J1: `general-purpose`

Runs after ALL Phase 1 agents complete. Blocked by tasks 1-6.

1. **Validate completeness** - did each agent cover all assigned files?
2. **Cross-cutting gaps** - issues spanning multiple agents' domains (same pattern in multiple files, inconsistent fixes)
3. **Verify T1's tests** - compile correctly, cover identified gaps
4. **Verify D1's docs** - accurate, match actual code
5. **Score each agent** (pass/needs-work)
6. **Produce fix list** - prioritized by security > correctness > concurrency > performance > style

---

## Phase 3: Fix Agents

For each issue the judge identifies as must-fix:

| Complexity | Agent Type | Example |
|------------|-----------|---------|
| 1-3 lines, single file | `fixer` | Default value change, remove a line |
| 5-20 lines, 1-2 files | `implementer` | Add guard pattern, replace API usage |
| 20+ lines, architecture | `swift-god` | Refactor a method, add new abstraction |

Launch ALL fix agents in parallel. After all complete, launch a final judge (`general-purpose`) that:
1. Reads every modified file
2. Verifies each fix addresses the identified issue
3. Runs `swift build` to confirm compilation
4. Reports PASS/FAIL per fix

---

## Execution Instructions

### Step 1: Create team
```
TeamCreate(team_name: "wax-review", description: "Code review of <branch-name> branch")
```

### Step 2: Create tasks for all Phase 1 agents + Phase 2 judge
- Tasks 1-3: R1, R2, R3 reviews
- Task 4: P1 performance audit
- Task 5: T1 test coverage
- Task 6: D1 documentation
- Task 7: J1 judge (addBlockedBy: [1,2,3,4,5,6])

### Step 3: Launch Phase 1 agents in parallel (single message, 6 Task tool calls)
- R1, R2, R3: `subagent_type: "swift-code-reviewer"`, `run_in_background: true`
- P1: `subagent_type: "feature-dev:code-explorer"`, `run_in_background: true`
- T1: `subagent_type: "general-purpose"`, `mode: "bypassPermissions"`, `run_in_background: true`
- D1: `subagent_type: "general-purpose"`, `mode: "bypassPermissions"`, `run_in_background: true`

### Step 4: As agents complete, mark tasks done and shutdown idle agents

### Step 5: When all Phase 1 complete, launch J1 judge
- `subagent_type: "general-purpose"`, `mode: "bypassPermissions"`, `run_in_background: true`

### Step 6: From judge output, create fix tasks and launch fix agents in parallel
- Match agent type to complexity (fixer/implementer/swift-god)
- All fixes run in parallel with `run_in_background: true`

### Step 7: Launch verification judge after all fixes complete
- Reads all modified files, runs `swift build`, reports PASS/FAIL per fix

### Step 8: Cleanup
- Shutdown all agents, TeamDelete

---

## Key Principles

1. **Parallel by default** - launch independent agents simultaneously
2. **Judge validates** - never trust agent output without cross-review
3. **Minimal fixes** - each fix should be focused, not over-engineered
4. **Build verification** - every fix phase ends with `swift build`
5. **Shutdown idle agents** - don't let them consume resources
6. **Cross-cutting awareness** - the judge catches patterns that span agent boundaries

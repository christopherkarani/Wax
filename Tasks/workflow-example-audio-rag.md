# Workflow Trace: Add AudioRAG Module

Example delegation chain showing routing, context handoff, file ownership, and findings flow.

---

## Team Setup

```
TeamCreate: team_name = "audio-rag-impl"
```

## Tasks

### Task 1: Gather Requirements
- **Agent**: `context-builder`
- **Blocked by**: —
- **Outputs**: `Tasks/audio-rag-context.md`

Read existing RAG modules (PhotoRAG, VideoRAG) for patterns. Write context document with requirements.

### Task 2: Design Architecture
- **Agent**: `wax-rag-specialist`
- **Blocked by**: Task 1
- **Outputs**: `Tasks/audio-rag-architecture.md`

Design frame kinds (`audio.root` → `audio.transcript`, `audio.speaker`), metadata keys, config struct, provider protocol.

### Task 3: Write Tests (TDD Red)
- **Agent**: `test-specialist`
- **Blocked by**: Task 2
- **File ownership**: `Tests/WaxIntegrationTests/AudioRAG*.swift`

Write tests: ingest hierarchy, speaker diarization, recall results, supersede behavior, deterministic timestamps. Confirm they fail.

### Task 4: Implement Source Files
- **Agent**: `implementer`
- **Blocked by**: Task 3
- **File ownership**: `Sources/Wax/AudioRAG/*.swift`

Create `AudioRAGConfig.swift`, `AudioRAGOrchestrator.swift`, `AudioRAGProtocols.swift`, `AudioRAGTypes.swift`. Implement to pass tests.

### Task 5: Build Verification
- **Agent**: `swift-debug-agent`
- **Blocked by**: Task 4

Run `swift build` and `swift test --filter AudioRAG`. Fix compilation errors.

### Task 6: Write Documentation
- **Agent**: `documenter`
- **Blocked by**: Task 5
- **File ownership**: `Sources/Wax/AudioRAG/CLAUDE.md`

Add `///` doc comments to public APIs. Create module CLAUDE.md.

### Task 7: Code Review
- **Agent**: `swift-code-reviewer`
- **Blocked by**: Task 5
- **Outputs**: `Tasks/audio-rag-review-findings.md`

Review against 9 invariants, Swift 6.2 concurrency, test coverage.

### Task 8: Apply Review Fixes
- **Agent**: `fixer` or `implementer`
- **Blocked by**: Task 7

Fix CRITICAL/HIGH findings. MEDIUM deferred with rationale. Run tests to verify.

---

## Context Flow

```
Task 1 (context-builder)
  └─ Tasks/audio-rag-context.md
       └─ Task 2 (wax-rag-specialist)
            └─ Tasks/audio-rag-architecture.md
                 └─ Task 3 (test-specialist)
                      └─ Tests/AudioRAG*.swift
                           └─ Task 4 (implementer)
                                └─ Sources/Wax/AudioRAG/*.swift
                                     ├─ Task 6 (documenter)
                                     └─ Task 7 (swift-code-reviewer)
                                          └─ Task 8 (fixer)
```

## File Ownership

| Files | Owner Task | Agent |
|-------|-----------|-------|
| `Tasks/audio-rag-*.md` | 1, 2 | context-builder, wax-rag-specialist |
| `Tests/.../AudioRAG*.swift` | 3 | test-specialist |
| `Sources/Wax/AudioRAG/*.swift` | 4, 5, 8 | implementer, swift-debug-agent, fixer |
| `Sources/Wax/AudioRAG/CLAUDE.md` | 6 | documenter |

No two tasks claim the same file concurrently. Task 8 inherits ownership only after Task 7 completes.

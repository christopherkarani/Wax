# Wax Framework — Agent Orchestration & Project Guide

## Project Overview

Wax is a Swift framework for on-device Retrieval-Augmented Generation (RAG) supporting photos, videos, PDFs, and extensible media types. It provides vector search, text search, unified search with RRF fusion, and deterministic context assembly.

- **Language**: Swift 6.2 with strict concurrency
- **Platforms**: iOS 26+ / macOS 26+
- **Architecture**: Actor-based orchestrators, protocol-driven providers, frame-based storage

## Build & Test Commands

```bash
swift build                                          # Build all targets
swift test                                           # Run all tests
swift test --filter WaxIntegrationTests              # Integration tests only
swift test --filter WaxCoreTests                     # Core unit tests (fast, no CoreML)
swift test --filter "PhotoRAGOrchestratorTests"       # Specific test suite
```

---

## Architecture Invariants (9 Rules)

Every change to Wax must respect these. Violations are blockers.

1. **Actor Isolation** — All orchestrators (`MemoryOrchestrator`, `PhotoRAGOrchestrator`, `VideoRAGOrchestrator`) are Swift actors. Mutable state lives inside actor boundaries.
2. **Sendable Boundary** — Values crossing actor boundaries must be `Sendable`. No `@unchecked Sendable` without an ADR.
3. **Frame Kind Hierarchy** — Root frames own children via `parentId`. Dot-namespaced kinds: `photo.root` → `photo.ocr`, `video.root` → `video.transcript`.
4. **Supersede-Not-Delete** — Re-ingesting calls `supersede(oldFrameId:)`. Never hard-delete frames.
5. **Capture-Time Semantics** — Frames use media capture time (EXIF, recording date), not ingest time.
6. **Deterministic Retrieval** — `TokenCounter.shared()` for cl100k_base. Deterministic tie-breaks. `FastRAGContextBuilder` produces identical output for identical input.
7. **Protocol-Driven Providers** — `MultimodalEmbeddingProvider`, `OCRProvider`, `CaptionProvider`, `VideoTranscriptProvider`. All with `ProviderExecutionMode`.
8. **On-Device Enforcement** — Core operations have no network calls. Providers MAY use network but are protocol-swappable.
9. **Two-Phase Indexing** — `session.put()` / `putBatch()` stages to WAL. `session.commit()` flushes to indexes.

---

## Agent Routing Table

This project has **Wax-specific agents** in `.claude/agents/` that encode domain knowledge. Use them alongside global generic agents.

| Task Type | Primary Agent | Support Agent(s) |
|-----------|--------------|-------------------|
| Requirements gathering | `context-builder` | — |
| New RAG module | `wax-rag-specialist` | `test-specialist`, `implementer` |
| Protocol implementation | `swift-god` | `test-specialist` |
| Bug fix (simple, 1-5 lines) | `fixer` | `swift-debug-agent` |
| Bug fix (complex, multi-file) | `implementer` | `swift-debug-agent`, `test-specialist` |
| Performance audit | `codebase-analyzer` | `wax-rag-specialist` |
| Code review | `swift-code-reviewer` | — |
| Test writing (TDD red) | `test-specialist` | — |
| Documentation | `documenter` | — |
| Build errors | `swift-debug-agent` | — |
| Context preservation | `wax-context-manager` | — |
| Architecture decisions | `wax-rag-specialist` | `context-builder` |

### Routing Rules

1. **When in doubt, start with `context-builder`** — it gathers requirements and research
2. **Never skip `test-specialist` for implementation tasks** — TDD is mandatory
3. **Use `wax-rag-specialist`** for anything touching frame kinds, metadata keys, orchestrator patterns, or search integration
4. **Use `swift-god` (Opus)** only for genuinely complex Swift problems — concurrency, generics, macros
5. **Use `fixer` (Haiku)** for trivial fixes — cheapest agent
6. **Use `implementer` (Sonnet)** for medium complexity — 5-50 lines, 1-3 files

### Agent Scoping

| Scope | Location | Agents |
|-------|----------|--------|
| **Project-specific** | `.claude/agents/` | `wax-rag-specialist`, `test-specialist`, `wax-context-manager` |
| **Global generic** | `~/.claude/agents/` | `implementer`, `fixer`, `documenter`, `context-manager` |
| **Built-in** | Claude Code | `swift-god`, `swift-debug-agent`, `swift-code-reviewer`, `context-builder`, `codebase-analyzer` |

---

## Workflow Templates

### Workflow A: New RAG Module
```
Phase 1: context-builder        → Gather requirements, research existing patterns
Phase 2: wax-rag-specialist     → Design frame kinds, metadata, config, orchestrator
Phase 3: test-specialist        → Write failing tests (TDD Red)
Phase 4: implementer/swift-god  → Implement to pass tests (TDD Green)
Phase 5: swift-debug-agent      → Verify build, fix compilation errors
Phase 6: documenter             → Add doc comments, update module CLAUDE.md
Phase 7: swift-code-reviewer    → Final review
```

### Workflow B: Bug Fix
```
Phase 1: context-builder        → Understand the bug, gather context
Phase 2: test-specialist        → Write regression test that reproduces the bug
Phase 3: fixer/implementer      → Fix the bug (minimal change)
Phase 4: swift-debug-agent      → Verify build + test-specialist verifies tests pass
```

### Workflow C: Performance Optimization
```
Phase 1: codebase-analyzer      → Profile and identify bottlenecks
Phase 2: wax-rag-specialist     → Design optimization approach
Phase 3: test-specialist        → Write baseline performance tests
Phase 4: implementer            → Implement optimization
Phase 5: test-specialist        → Verify improvement + swift-code-reviewer
```

### Workflow D: Code Review
Reference `Tasks/swarm-review-workflow.md` for the full multi-agent review protocol.

---

## Shared Context Protocol

### Context Handoff Format

Written to `Tasks/<task-slug>-context.md` by `wax-context-manager`:

| Section | Content |
|---------|---------|
| Decisions | Decision, rationale, reversible? |
| Progress | Checklist of completed/pending steps |
| Modified Files | File path, change summary, agent |
| Wax Context | Actors crossed, frame kinds, metadata keys, invariants in play |
| Handoff Notes | What the next agent needs to know |
| Open Questions | Unresolved items |

### Findings Accumulator (Review Workflows)

1. Reviewers write findings with severity (CRITICAL / HIGH / MEDIUM / LOW)
2. Judge deduplicates and prioritizes
3. Fix agents receive specific assignments with file paths
4. Verification judge confirms fixes

### Decision Log

Architectural Decision Records in `docs/adr/NNN-title.md` — proposed → accepted → superseded.

---

## Conflict Resolution Rules

1. **File ownership**: Tasks declare file lists. No two concurrent tasks claim the same file.
2. **Merge conflicts**: First committer wins. Second agent re-reads and rebases.
3. **Test vs implementation**: Test defines expected behavior (TDD). Implementer must match or escalate to `wax-rag-specialist`.
4. **Review severity**: CRITICAL = must fix. HIGH = must fix unless specialist exempts. MEDIUM = defer with rationale. LOW = implementer decides.
5. **Architecture disputes**: Both positions documented → `wax-rag-specialist` arbitrates → ADR recorded.

---

## Quality Gates

1. `swift build` succeeds with zero errors
2. `swift test` passes with all new tests present
3. TDD compliance (tests before implementation)
4. No `@unchecked Sendable` or `nonisolated(unsafe)` without documented justification
5. Public APIs have `///` doc comments
6. Module CLAUDE.md updated if architecture changed
7. No `!` or `try!` in production code
8. Deterministic token counting, tie-breaks, and context assembly

---

## Per-Module CLAUDE.md Reference

Agents should read the relevant module CLAUDE.md before making changes.

| Module | Location |
|--------|----------|
| Wax (main) | `Sources/Wax/CLAUDE.md` |
| Ingest | `Sources/Wax/Ingest/CLAUDE.md` |
| Orchestrator | `Sources/Wax/Orchestrator/CLAUDE.md` |
| PhotoRAG | `Sources/Wax/PhotoRAG/CLAUDE.md` |
| RAG | `Sources/Wax/RAG/CLAUDE.md` |
| UnifiedSearch | `Sources/Wax/UnifiedSearch/CLAUDE.md` |
| VideoRAG | `Sources/Wax/VideoRAG/CLAUDE.md` |
| WaxCore | `Sources/WaxCore/CLAUDE.md` |
| Concurrency | `Sources/WaxCore/Concurrency/CLAUDE.md` |
| MiniLM/CoreML | `Sources/WaxVectorSearchMiniLM/CoreML/CLAUDE.md` |
| Core Tests | `Tests/WaxCoreTests/CLAUDE.md` |
| Integration Tests | `Tests/WaxIntegrationTests/CLAUDE.md` |

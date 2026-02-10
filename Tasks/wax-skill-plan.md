# Wax Codex Skill Plan (Tier 2, Immutable)

**Status:** Immutable after creation.  
**Scope:** Create a comprehensive Codex skill for the Wax framework.

## Goals
1. Provide a first-class Codex skill that teaches Wax usage, public API, and best practices.
2. Cover MemoryOrchestrator and VideoRAGOrchestrator with accurate, task-oriented guidance.
3. Encode Wax constraints (offline-only, single-file persistence, transcript requirements) clearly.
4. Enable safe, correct usage patterns with strong Swift 6.2 type safety emphasis.
5. Include verified references to public APIs, configuration knobs, and lifecycle flows.

## Constraints and Non-Goals
- Non-goal: implement Wax features or modify library code.
- Non-goal: produce runnable demo apps unless explicitly requested later.
- Constraint: skill content must align with current public APIs and modules.
- Constraint: no claims outside README/Sources/Tests context unless validated by web research.
- Constraint: keep guidance consistent with Swift 6.2, iOS 26/macOS 26 requirements.
- Constraint: avoid speculative performance promises; cite existing benchmark framing only.

## Architecture Decisions (Skill Structure and References)
1. **Skill location and structure**
   - Create a new skill under `$CODEX_HOME/skills/wax/`.
   - Primary entry: `SKILL.md`.
   - Supporting references: `references/` for curated snippets and API maps.
   - Templates: `templates/` for task patterns (ingest, recall, maintenance).
2. **Reference sources**
   - Use local repository as the authoritative source.
   - Reference: `README.md`, `Sources/Wax` public API declarations, and tests.
   - Avoid quoting private or internal types beyond what is in public modules.
3. **Content sections**
   - Quickstart with MemoryOrchestrator.
   - Configuration and embedder policies.
   - Retrieval modes and RAGContext handling.
   - Maintenance: optimizeSurrogates, compactIndexes, flush/close.
   - VideoRAG: requirements, ingest, recall, transcripts.
   - Determinism and crash safety invariants.
4. **Skill behavior**
   - Prescriptive safety checks: vector search and embedder availability, query embedding policy constraints.
   - Strong defaults: on-device/offline emphasis, deterministic retrieval explanation.
   - Provide guardrails for typical misuse.

## Detailed To-Do List (Granular)
1. **Context pass**
   - Extract public APIs from `Sources/Wax` and verify signatures.
   - Extract constraints and positioning from `README.md`.
   - Extract edge cases and failure modes from tests.
2. **Skill skeleton**
   - Create `SKILL.md` with purpose, trigger rules, and usage workflow.
   - Add a minimal glossary of key Wax types and concepts.
3. **API reference map**
   - Add `references/public-api.md` with MemoryOrchestrator, VideoRAGOrchestrator, core protocols, and key types.
   - Document configuration flags and policy constraints (e.g., QueryEmbeddingPolicy behavior).
4. **Task playbooks**
   - Add templates for:
     - Initialize store and embedder.
     - Remember/recall flows with lifecycle.
     - Hybrid search mode usage.
     - Maintenance tasks (optimize, compact, flush, close).
     - VideoRAG ingest/recall with transcripts.
5. **Safety and correctness**
   - Add explicit misuse warnings: embedder requirements, vector search enablement rules, offline-only constraints.
   - Add deterministic retrieval notes and token budget caveats.
6. **Examples**
   - Provide concise Swift examples in `SKILL.md` that align with public API.
   - Include failure handling patterns (throws, do/catch).
7. **Review pass**
   - Validate skill content against sources and tests.
   - Ensure no new claims without evidence.
   - Tighten wording for API clarity and Swift type safety.

## Task → Agent Mapping
1. **Context/Research Agent**
   - Responsibilities: verify public APIs and constraints from repository files.
   - Output: a concise, source-linked summary for planning and documentation.
2. **Planning Agent**
   - Responsibilities: author immutable plan (this document).
   - Output: final plan markdown.
3. **Task Decomposition Agent**
   - Responsibilities: split plan into `.md` task files with Prompt/Goal/Breakdown/Expected Output.
   - Output: tasks under `Tasks/` or designated folder.
4. **Test-First Agent**
   - Responsibilities: create a validation checklist and example snippets. No code execution required.
5. **Implementation Agent**
   - Responsibilities: author `SKILL.md`, references, and templates.
6. **Code Review Agent(s)**
   - Responsibilities: verify correctness, safety, API alignment.
   - Count: 2 (medium complexity).
7. **Fix/Gap Agent**
   - Responsibilities: patch gaps identified by review and re-validate.

## Deliverables
1. `SKILL.md` for Wax skill.
2. `references/public-api.md`.
3. `templates/` for common tasks.
4. A short validation checklist.

## Plan Immutability
This plan is the single source of truth and must not be edited after approval.

- Concise summary:
- Tier-2 plan prepared with goals, constraints, architecture, tasks, and agent mapping.
- Skill structure centered on `SKILL.md` plus references and templates.
- Emphasis on correctness, Swift type safety, and offline deterministic constraints.
- Task flow aligns with Wax public APIs and tests without speculative claims.

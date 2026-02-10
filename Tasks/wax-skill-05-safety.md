Prompt:
You are the Implementation Agent. Add safety and correctness guardrails to the skill content.

Goal:
Ensure the skill explicitly warns about misuse patterns and documents deterministic and offline constraints.

Task Breakdown:
- Add warnings about embedder requirements and vector search enablement.
- Add notes on offline-only constraints and single-file persistence rules if verified.
- Add deterministic retrieval and token budget caveats based on sources.

Expected Output:
Updated `SKILL.md` sections (or a dedicated safety section) with clear, source-based warnings and constraints.

Prompt:
Break Phase 0–2 into a focused task for reproducing and diagnosing the signal 11 crash. Do not change the plan text; implement only the work needed for reproducible crash evidence and suspected root-cause isolation.
Goal:
Produce a repeatable crash reproduction with concrete artifacts (commands, logs, env, machine details, backtraces) and narrow likely causes (global init/Metal/CoreML/concurrency) with minimal noise.
Task BreakDown
- Capture exact failing command(s), environment variables, machine details, and build mode for the crash (Phase 0).
- Stabilize the environment to reduce noise (consistent build mode, relevant env flags only) (Phase 1).
- Reproduce signal 11 with a minimal filter; collect backtraces and crash logs (Phase 2).
- Identify likely suspects (global init, Metal, CoreML, concurrency) and propose next isolation steps (Phase 2).

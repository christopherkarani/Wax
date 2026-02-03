Prompt:
Break Phase 3 into a focused task to investigate the RAGPerformanceBenchmarks hang. Do not change the plan text; focus on confirm hang vs slow, logging, and deadlock/resource checks.
Goal:
Determine whether the benchmark is hanging or merely slow, and gather evidence (logs, timeouts, resource signals) that indicates the blocking point.
Task BreakDown
- Confirm hang vs slow by timing runs and adding minimal logging (Phase 3).
- Check for deadlocks, timeouts, or resource contention (Phase 3).
- Capture enough data to point to the blocking component without changing benchmark intent (Phase 3).

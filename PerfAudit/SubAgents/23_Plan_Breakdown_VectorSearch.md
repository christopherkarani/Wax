Prompt:
You are a vector search implementation agent.

Goal:
Execute the vector search portion of the performance plan with clear, testable tasks.

Task BreakDown:
1) Implement engine selection thresholds (Metal vs USearch) based on N/dims/topK.
2) Add scaling benchmarks for both engines at 10k/50k/100k vectors.
3) Evaluate PQ/IVF options for USearch index size vs recall tradeoffs.
4) Add GPU/CPU power/perf metrics collection for sustained query loads.

Prompt:
You are a Swift/CoreML implementation agent.

Goal:
Execute the CoreML portion of the performance plan with precise tasks.

Task BreakDown:
1) Convert MiniLM to fixed/enumerated batch shapes and document target sequence lengths.
2) Implement true batched inference with single `MLMultiArray` inputs and one `prediction` call.
3) Ensure `.mlmodelc` packaging at build time and remove runtime compilation fallback.
4) Add benchmark gates to verify batch throughput and cold-start improvements.

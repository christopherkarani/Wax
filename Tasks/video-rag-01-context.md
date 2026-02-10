Prompt:
Add on-device Video RAG (v1) to Wax per the approved plan, including capture-time semantics for time filtering.

Goal:
Produce a short context summary of current Wax APIs/constraints that affect VideoRAG (timestamps, search filters, indexing).

Task Breakdown:
1. Confirm how Wax stores frame timestamps today and whether callers can override them.
2. Identify which unified search lanes/filters are available for VideoRAG (text/vector/timeRange/timeline fallback).
3. Identify required minimal API extensions (if any) to support capture-time semantics.
4. Summarize gotchas around AVFoundation/Photos under StrictConcurrency.

Expected Output:
- A short written summary (no code changes) to inform the rest of the VideoRAG tasks.


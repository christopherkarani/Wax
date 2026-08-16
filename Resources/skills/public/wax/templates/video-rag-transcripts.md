Template: Video RAG (package-only in v1)
Goal: Explain the status of video RAG and the supported integration path.

The video RAG pipeline (`VideoRAGOrchestrator`, `VideoFile`, `VideoQuery`,
`VideoTranscriptProvider`) is **package-only** in the current release: downstream Swift
apps cannot import or construct it. Do not generate client code against it.

There are **no** Wax MCP `video_*` tools today (see `Sources/WaxMCPServer/ToolSchemas.swift`).

Supported path today:
1. Host apps (or agents with transcript text) store transcript text and metadata in
   `Memory` via `save` / MCP `remember`, then search with the standard text/vector lanes
   (`Memory.search` or MCP `recall` / `search`). Wax does not transcribe in v1 — supply
   transcripts yourself.
2. Keep content concise and task-scoped; use metadata keys (for example `source=video`,
   `asset_id`, timestamps) so later retrieval can filter or cite provenance.

A stable public video facade and any MCP video tools will be documented here when they ship.

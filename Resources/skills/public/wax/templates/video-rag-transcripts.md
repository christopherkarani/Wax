Template: Video RAG (package-only in v1)
Goal: Explain the status of video RAG and the supported integration path.

The video RAG pipeline (`VideoRAGOrchestrator`, `VideoFile`, `VideoQuery`,
`VideoTranscriptProvider`) is **package-only** in the current release: downstream Swift
apps cannot import or construct it. Do not generate client code against it.

Supported paths today:
1. Agent workflows: use the Wax MCP server video tools (`video_*`), which run the
   pipeline inside the Wax process. Host apps supply transcripts — Wax does not
   transcribe in v1.
2. Swift apps: store transcript text and metadata in `Memory` and search it with the
   standard text/vector lanes.

A stable public video facade will be documented here when it ships.

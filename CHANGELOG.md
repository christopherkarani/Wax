# Changelog

All notable changes to the Wax MCP server (`waxmcp`) are documented here.

## [0.1.2] - 2026-02-23

### Fixed
- MCP server crash on missing embedder: auto-fallback to text-only mode when no MiniLM embedder is available
- Malformed JSON in tool response encoding
- Unsafe arithmetic in frame count delta calculation
- Signal handling: SIGINT/SIGTERM now trigger graceful shutdown instead of immediate termination

### Added
- Structured memory tools: `wax_entity_upsert`, `wax_fact_assert`, `wax_fact_retract`, `wax_facts_query`, `wax_entity_resolve`

### Removed
- Video and photo RAG tools deferred to a future release (`wax_video_ingest`, `wax_video_recall`, `wax_photo_ingest`, `wax_photo_recall`)
- Startup log line: `WaxMCPServer vX.Y.Z starting`
- Version exposed in MCP `initialize` handshake `serverInfo`

## [0.1.1] - 2026-01-15

### Added
- Session-scoped memory: `wax_session_start`, `wax_session_end`
- Handoff tools: `wax_handoff`, `wax_handoff_latest`
- License validation (opt-in via `WAX_MCP_FEATURE_LICENSE`)

### Fixed
- WAL checkpoint now runs on clean shutdown

## [0.1.0] - 2025-12-01

### Added
- Initial release
- `wax_remember`, `wax_recall`, `wax_search`, `wax_flush`, `wax_stats` tools
- Stdio MCP transport with `StdioTransport`
- MiniLM embeddings support via `WaxVectorSearchMiniLM`
- npm launcher (`waxmcp`) with bundled darwin-arm64 and darwin-x64 binaries

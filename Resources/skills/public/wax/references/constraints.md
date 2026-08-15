# Constraints and limits

Read when search/save results look wrong, the store is large, or you need hard limits.

## Offline and single-file persistence

- On-device only — no network calls from Wax itself.
- One `.wax` file: data, indexes, metadata, WAL.
- Not a cloud sync service.

## Public API boundary

- Apps: `Memory` only.
- Structured / photo / video memory: MCP/agent surfaces, not app imports.

## Vector search and embeddings

- MiniLM / Arctic: iOS 18 / macOS 15+ + traits (`MiniLMEmbeddings` default-on).
- `.hybrid` degrades to text without a usable vector lane; `.vectorOnly` throws `WaxError.io`.
- `RAGContext.diagnostics` reports requested vs effective mode.
- Query embedding timeout (~10s) can open a ~60s circuit breaker.
- Metal HNSW ~10,000+ vectors; smaller stores use exact CPU index.

## Persistence lifecycle

- `save` → WAL; `flush` → durable commit; `close` → flush + close.
- Unflushed WAL is recovered on the next successful open; still flush before iOS suspension.
- `delete(frameID:)` updates indexes immediately. One frame only — chunk siblings from the same `save` may remain; filter recall against your transcript for “delete message” UX.

## Ingest behavior

- One `save` may create a document frame plus chunk frames — dedupe UI by metadata id.
- Content-hash dedup can collapse identical text without a unique metadata key.
- Variadic `save` has no metadata channel.
- Existing vector index + no embedder → `save` throws `missingEmbedder` (see `app-integration.md`).

## What Wax cannot do for apps

- Enumerate/page all frames without a search query.
- Be the sole ordered transcript store.
- Expose photo/video orchestrators to downstream apps.

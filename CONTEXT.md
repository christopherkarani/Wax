# Wax

On-device memory for agents and apps: durable frames, text and vector recall, and host-facing tools over the same store.

## Language

**Memory**:
The public store an app opens for text save, search, delete, flush, and stats.
_Avoid_: MemoryOrchestrator, WaxSession, Wax actor

**PhotoMemory**:
The public store for photo ingest and recall. Experimental.
_Avoid_: PhotoRAGOrchestrator

**VideoMemory**:
The public store for video ingest and recall. Hosts supply transcripts; Wax does not transcribe or store media bytes. Experimental.
_Avoid_: VideoRAGOrchestrator

**Automatic** (embedding source):
The store prefers a built-in provider but is usable without one.
_Avoid_: auto embedder, best-effort MiniLM

**Built-in** (embedding source):
A required on-device provider. Opening the store fails if it cannot activate.
_Avoid_: MiniLMEmbedder, forced embedder

**Custom** (embedding source):
A host-supplied provider, already active.
_Avoid_: user embedder, injected embedder

**Embedding readiness**:
Whether a store has a usable embedding provider, including load, status, and the missing-provider rule.
_Avoid_: embedder factory, deferred embedder, CommandLineEmbedderFactory

**Embedding identity**:
The provider's own name for itself (model, dimensions, normalization). One provider, one identity.
_Avoid_: MiniLM vs MiniLMAll as two identities, wrapper-stamped identity

**Embedding status**:
Readiness of the embedding provider attached to a store: disabled, loading, active, degraded, or unavailable.

**Unavailable** (embedding):
No provider could be activated. A vector index may still exist; hybrid search is text; vector-only search fails.
_Avoid_: degraded, text-only fallback (as a status name)

**Degraded** (embedding):
A provider is active, but some existing frames have no vectors.
_Avoid_: unavailable, ghost vectors

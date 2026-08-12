# Session Management

Understand how Wax manages persistence sessions.

## Overview

``WaxSession`` is a package-only implementation detail, not public API. Application code should use ``Memory``, which manages sessions internally. (`MemoryOrchestrator`, `PhotoRAGOrchestrator`, and `VideoRAGOrchestrator` are also package-only and not callable from outside the Wax package.)

The ``Memory`` actor opens, stages, commits, and closes internal sessions as needed. It also coordinates writer access with the underlying WaxCore store so callers do not construct lower-level sessions directly.

## Public Lifecycle

Create one ``Memory`` per store URL and close it when the store is no longer needed:

```swift
let memory = try await Memory(at: storeURL)
try await memory.save("New content")
let results = try await memory.search("content")
_ = results.items

try await memory.close()
```

Call ``Memory/flush()`` when you need to force pending indexes and frame metadata to disk before process shutdown. ``Memory/close()`` flushes automatically.

## Writer Behavior

WaxCore allows multiple readers and one writer. ``Memory`` acquires and releases writer access internally during write operations. If an application needs external coordination, serialize writes at the ``Memory`` boundary instead of constructing package-only session types.

## Search Configuration

Configure search behavior through ``Memory/Config``. For text-only usage, set `enableVectorSearch = false`. For semantic recall, keep `enableVectorSearch` enabled — the built-in MiniLM embedder is wired automatically on iOS 18/macOS 15+ (default `MiniLMEmbeddings` trait), or pass a custom `EmbeddingProvider` to ``Memory/init(at:config:embedding:)``.

Use ``Memory/stats()`` and ``RAGContext/diagnostics`` to verify which retrieval lanes are actually active.

## Lower-Level Internals

The package-only session layer handles:

- Writer leases for exclusive mutation.
- Text, vector, and structured-memory index staging.
- Commit ordering between frame payloads, indexes, and table-of-contents metadata.
- Search delegation to the unified search engine.

These details are documented here only to explain behavior and durability guarantees; they are not user-constructible APIs.

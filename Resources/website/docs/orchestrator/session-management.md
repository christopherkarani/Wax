---
sidebar_position: 4
title: "Session Management"
sidebar_label: "Session Management"
---

Understand how public orchestrators manage persistence sessions.

## Overview

`WaxSession` is a package-only implementation detail, not public API. Application code should use `MemoryOrchestrator` for text memory, `PhotoRAGOrchestrator` for photo RAG, or `VideoRAGOrchestrator` for video RAG.

The orchestrators open, stage, commit, and close internal sessions as needed. They also coordinate writer access with the underlying WaxCore store so callers do not construct lower-level sessions directly.

## Public Lifecycle

Create one orchestrator per store URL and close it when the store is no longer needed:

```swift
let memory = try await MemoryOrchestrator(at: storeURL)
try await memory.remember("New content")
let context = try await memory.recall(query: "content")
_ = context.items

try await memory.close()
```

Call `MemoryOrchestrator.flush()` when you need to force pending indexes and frame metadata to disk before process shutdown.

## Writer Behavior

WaxCore allows multiple readers and one writer. Public orchestrators acquire and release writer access internally during write operations. If an application needs external coordination, serialize writes at the orchestrator boundary instead of constructing package-only session types.

## Search Configuration

Configure public search behavior through `OrchestratorConfig` and `FastRAGConfig`. For text-only usage, disable vector search. For semantic recall, provide an `EmbeddingProvider` and keep `OrchestratorConfig.enableVectorSearch` enabled.

## Lower-Level Internals

The package-only session layer handles:

- Writer leases for exclusive mutation.
- Text, vector, and structured-memory index staging.
- Commit ordering between frame payloads, indexes, and table-of-contents metadata.
- Search delegation to the unified search engine.

These details are documented here only to explain behavior and durability guarantees; they are not user-constructible APIs.

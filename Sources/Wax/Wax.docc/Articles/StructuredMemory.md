# Structured Memory

Store entities, facts, and edges beside text memory using the public ``Memory`` APIs.

## Overview

Structured memory is **public** on ``Memory`` when ``Memory/Config-swift.struct/enableStructuredMemory`` is `true`. The MCP server tools (`entity_upsert`, `fact_assert`, …) remain available for agents; Swift apps no longer need those tools to persist facts.

DTOs live on ``Memory``: ``Memory/EntityMatch``, ``Memory/FactHit``, ``Memory/FactsResult`` (the field is ``Memory/FactsResult/hits``, not `.facts`), ``Memory/FactID``, ``Memory/EntityID``, ``Memory/FactValue``, ``Memory/FactRelation``, ``Memory/Edge``, and ``Memory/EdgeDirection``.

`MemoryOrchestrator` structured types stay package-only.

## Enable and use

```swift compile
import Foundation
import Wax

func structuredMemoryDemo() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "structured.wax")
    var config = Memory.Config.default
    config.enableVectorSearch = false
    config.enableStructuredMemory = true
    let memory = try await Memory(at: storeURL, config: config)

    _ = try await memory.upsertEntity(
        key: "person:alice",
        kind: "person",
        aliases: ["Alice", "A. Example"]
    )

    let resolved = try await memory.resolveEntities(alias: "Alice")
    precondition(resolved.map(\.key) == ["person:alice"])

    let factID = try await memory.assertFact(
        subject: "person:alice",
        predicate: "favoriteTea",
        object: .string("oolong")
    )

    let found = try await memory.facts(subject: "person:alice", predicate: "favoriteTea")
    precondition(found.hits.count == 1)
    precondition(found.hits[0].object == .string("oolong"))
    precondition(found.hits[0].id == factID)
    precondition(found.wasTruncated == false)

    let graph = try await memory.edges(for: "person:alice", direction: .outbound)
    _ = graph.hits

    try await memory.retractFact(factID)
    try await memory.close()
}
```

When `enableStructuredMemory` is `false`, these methods throw `WaxError.featureDisabled(feature:)` with `feature` `"structured memory"`.

---
sidebar_position: 1
title: "MiniLM Embeddings"
sidebar_label: "MiniLM Embeddings"
---

:::warning App targets: use `Config.embedding` / `BuiltInEmbeddings`
`MiniLMEmbedder` is **package-internal** (Swift `package` access). Downstream apps cannot construct `MiniLMEmbedder()`. Select the on-device MiniLM model through [`Memory.Config.embedding`](../ios/memory-api) or `BuiltInEmbeddings.make(.miniLM)`. This page documents the public app path first; package internals are noted for contributors.
:::

Set up and tune on-device MiniLM embeddings for Wax vector search.

## App setup (public API)

On iOS 18 / macOS 15+ with the default `MiniLMEmbeddings` package trait, `Memory(at:)` wires MiniLM automatically via `Config.embedding = .automatic`:

```swift
let memory = try await Memory(at: storeURL)
```

Force the built-in provider (throws if unavailable on this OS/build):

```swift
let memory = try await Memory(at: storeURL) { config in
    config.embedding = .builtIn(.miniLM)
}
```

Or construct a provider and pass it as custom:

```swift
let provider = try await BuiltInEmbeddings.make(.miniLM)
let memory = try await Memory(at: storeURL) { config in
    config.embedding = .custom(provider)
}
```

Tune built-in construction with `BuiltInEmbeddingProviderOptions` (batch size, prewarm, compute-unit order, timeout):

```swift
var options = BuiltInEmbeddingProviderOptions.default
options.batchSize = 128
options.prewarmBatchSize = 16
options.computeUnitsOrder = [.cpuAndNeuralEngine, .cpuOnly]

let provider = try await BuiltInEmbeddings.make(.miniLM, options: options)
```

See [`Memory` API](../ios/memory-api) and `Sources/Wax/BuiltInEmbeddings.swift`.

## What MiniLM provides

The all-MiniLM-L6-v2 CoreML path implements `EmbeddingProvider` and `BatchEmbeddingProvider`: tokenization, inference, batch planning, and L2-normalized 384-d vectors. Apps reach that behavior only through `Config.embedding` / `BuiltInEmbeddings` — not by naming `MiniLMEmbedder`.

## Contributor notes (package-only)

Inside the Wax package (CLI, MCP, tests), `MiniLMEmbedder` owns CoreML model loading and batch optimization. Do not generate app samples that call `MiniLMEmbedder()`.

Characteristics useful when diagnosing contributor builds:

| Property | Value |
|----------|-------|
| Dimensions | 384 |
| Normalization | L2 |
| Max tokens | 512 (BERT limit) |
| Default compute | `.cpuAndNeuralEngine` |
| Output | Float16 → Float32 via Accelerate |

Sequence-length bucketing (32…512), batch splitting, and ANE diagnostics are package implementation details behind `BuiltInEmbeddings`.

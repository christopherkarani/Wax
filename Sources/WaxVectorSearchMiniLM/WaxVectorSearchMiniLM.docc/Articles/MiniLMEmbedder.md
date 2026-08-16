# MiniLM Embeddings

Set up and tune on-device MiniLM embeddings for Wax vector search.

## Status

``MiniLMEmbedder`` is package-only (`package` access). Application and downstream package consumers **cannot** construct it. Use ``Memory/Config/embedding`` or ``BuiltInEmbeddings`` instead (see <doc:GettingStarted>).

This article documents the public app path first. Package-internal CoreML details are for Wax contributors.

## App setup (public API)

On iOS 18 / macOS 15+ with the default `MiniLMEmbeddings` package trait, ``Memory`` wires MiniLM automatically via ``Memory/Config/embedding`` `.automatic`:

```swift
let memory = try await Memory(at: storeURL)
```

Force the built-in provider (throws if unavailable):

```swift
let memory = try await Memory(at: storeURL) { config in
    config.embedding = .builtIn(.miniLM)
}
```

Or construct via ``BuiltInEmbeddings``:

```swift
let provider = try await BuiltInEmbeddings.make(.miniLM)
let memory = try await Memory(at: storeURL) { config in
    config.embedding = .custom(provider)
}
```

Tune with ``BuiltInEmbeddingProviderOptions`` (batch size, prewarm, compute-unit order, timeout).

## What MiniLM provides

The all-MiniLM-L6-v2 CoreML path implements `EmbeddingProvider` and `BatchEmbeddingProvider`: tokenization, inference, batch planning, and L2-normalized 384-d vectors. Apps reach that behavior only through ``Memory/Config/embedding`` / ``BuiltInEmbeddings``.

## Contributor notes (package-only)

Inside the Wax package (CLI, MCP, tests), `MiniLMEmbedder` owns CoreML model loading and batch optimization. Do not publish app samples that call `MiniLMEmbedder()`.

| Property | Value |
|----------|-------|
| Dimensions | 384 |
| Normalization | L2 |
| Max tokens | 512 (BERT limit) |
| Default compute | `.cpuAndNeuralEngine` |
| Output | Float16 → Float32 via Accelerate |

Sequence-length bucketing, batch splitting, and ANE diagnostics remain package implementation details behind ``BuiltInEmbeddings``.

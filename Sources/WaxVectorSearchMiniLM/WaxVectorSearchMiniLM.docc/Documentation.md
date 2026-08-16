# ``WaxVectorSearchMiniLM``

On-device sentence embeddings via CoreML with the all-MiniLM-L6-v2 transformer model.

## Overview

WaxVectorSearchMiniLM provides the package-internal CoreML MiniLM stack used by Wax’s built-in embeddings. Application code should **not** import this module or construct ``MiniLMEmbedder``. Use the public Wax facade instead:

```swift
import Wax

// Automatic MiniLM on iOS 18/macOS 15+ (default MiniLMEmbeddings trait)
let memory = try await Memory(at: storeURL)

// Or force / customize via Config.embedding / BuiltInEmbeddings
let memoryForced = try await Memory(at: storeURL) { config in
    config.embedding = .builtIn(.miniLM)
}
let provider = try await BuiltInEmbeddings.make(.miniLM)
```

The module wraps the [all-MiniLM-L6-v2](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2) sentence transformer as a compiled CoreML model with a full BERT WordPiece tokenizer. It produces 384-dimensional, L2-normalized embeddings optimized for semantic similarity search.

### Key Characteristics

| Property | Value |
|----------|-------|
| Dimensions | 384 |
| Normalization | L2-normalized |
| Max tokens | 512 (BERT limit) |
| Compute | Neural Engine + CPU (default) |
| Quantization | Float16 output, converted to Float32 |
| Execution mode | On-device only (no network) |
| App access | Via ``Memory/Config/embedding`` / ``BuiltInEmbeddings`` only |

This module is conditionally compiled via the `MiniLMEmbeddings` package trait, which is enabled by default.

## Topics

### Essentials

- <doc:MiniLMEmbedder>
- ``MiniLMEmbedder``

### CoreML Integration

- ``MiniLMEmbeddings``
- ``BertTokenizer``

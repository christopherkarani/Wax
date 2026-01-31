# Wax Project Documentation

## 1. Public Facing Developer API

The primary public API for developers is exposed through the `Wax` library, specifically via high-level session actors that manage access to the underlying storage and search engines.

### `WaxTextSearchSession`
**Purpose**: Handles full-text search operations using FTS5.
- **Key Methods**:
    - `index(frameId:text:)`: Index a single document.
    - `indexBatch(frameIds:texts:)`: optimized batch indexing.
    - `search(query:topK:)`: Execute a text search query.
    - `stageForCommit(compact:)`: Prepare changes for commit.
    - `commit(compact:)`: Persist changes to disk.

### `WaxVectorSearchSession`
**Purpose**: Handles semantic vector search operations, supporting both CPU (USearch) and GPU (Metal) backends.
- **Key Methods**:
    - `add(frameId:vector:)`: Add a single vector to the index.
    - `putWithEmbedding(...)`: combined operation to store content and index its embedding.
    - `putWithEmbeddingBatch(...)`: High-performance batch insertion of content and embeddings.
    - `search(vector:topK:)`: Find nearest neighbors for a query vector.
    - `stageForCommit()`: Prepare vector index changes for commit.

## 2. API Surface for AI Agents

The `MemoryOrchestrator` provides a high-level abstraction specifically designed for AI agents to maintain long-term memory and perform Retrieval Augmented Generation (RAG).

### `MemoryOrchestrator` (Actor)
**Purpose**: Manages the full lifecycle of agent memory (Ingest -> Storage -> Recall).
- **Core Methods**:
    - `startSession() -> UUID`: Begin a new tagged session.
    - `endSession()`: End the current session.
    - `remember(_:metadata:)`: Ingest text content. Automatically handles chunking, embedding generation, and storage.
    - `recall(query:) -> RAGContext`: Retrieve relevant context for a query. Uses a sophisticated RAG pipeline.
    - `flush()`: Ensure all memory is persisted to disk.

### `FastRAGContextBuilder`
**Purpose**: Builds deterministic RAG contexts for LLMs.
- **Core Method**: `build(query:embedding:...) -> RAGContext`
- **Pipeline**:
    1.  **Search**: Unified search (Text + Vector) with Reciprocal Rank Fusion (RRF).
    2.  **Expansion**: Expands the top result to full frame content if within token limits.
    3.  **Surrogates**: Fetches content for other high-ranking results (densecached mode).
    4.  **Snippets**: Fills remaining context window with relevant snippets.

## 3. Important Internals

### `Wax` (Actor)
**Location**: `Sources/WaxCore/Wax.swift`
**Role**: The central engine of the framework. It manages the `.mv2s` file format, concurrency, and caching.
- **Responsibilities**:
    - Managing the `FDFile` (file descriptor) and `FileLock`.
    - Handling the Write-Ahead Log (WAL) via `WALRingWriter`.
    - Managing the Table of Contents (TOC) and Footer.
    - coordinating commits and data consistency.

### Storage Format (`.mv2s`)
- **Header**: Versioning and offsets.
- **WAL**: Ring buffer for append-only writes, ensuring durability and crash recovery.
- **TOC**: Table of Contents mapping frames to their locations.
- **Payload**: Raw data storage.

### `WALRingWriter`
**Location**: `Sources/WaxCore/WAL`
**Role**: Manages the Write-Ahead Log.
- **Mechanism**: Writes changes to a ring buffer before they are committed to the main data area. This ensures that in the event of a crash, pending mutations can be recovered or discarded safely.

## 4. Mission Critical Functions and Algorithms

### Vector Search Optimization
- **Hybrid Engine**: Automatically selects between `MetalVectorEngine` (GPU-accelerated) and `USearchVectorEngine` (CPU-optimized) based on availability.
- **Batching**: `putWithEmbeddingBatch` minimizes initialization overhead and maximizes throughput by batching WAL writes and vector index updates.

### Embedding Memoizer
- **Algorithm**: Logical timestamp-based caching or LRU (implementation detail in `EmbeddingMemoizer`).
- **Function**: Prevents re-computing embeddings for known text chunks during ingestion, significantly speeding up the `remember` flow.

### Fast RAG Pipeline
**Algorithm in `FastRAGContextBuilder.build`**:
1.  **Unified Search**: Executes text and/or vector search.
2.  **Ranking**: Merges results.
3.  **Context Construction**:
    -   **Priority 1 (Expansion)**: The single best match is expanded to full text.
    -   **Priority 2 (Surrogates)**: Other high-ranking matches are included as full "surrogate" frames if they fit.
    -   **Priority 3 (Snippets)**: Short previews of other results are added until the token limit is reached.
-   **Token Management**: Uses `TokenCounter` to strictly adhere to the context window limits (e.g., 8192 tokens), ensuring the LLM prompt never overflows.

### Ingestion Pipeline (`MemoryOrchestrator.remember`)
1.  **Chunking**: `TextChunker` splits input text.
2.  **Parallel Embedding**: Uses `TaskGroup` to generate embeddings for chunks in parallel (or batched if supported).
3.  **Batch Write**: Writes content and embeddings to `Wax` in a single transaction-like batch to minimize I/O lock contention.

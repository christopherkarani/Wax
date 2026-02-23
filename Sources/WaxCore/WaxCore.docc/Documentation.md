# ``WaxCore``

The foundational persistence layer for Wax: a crash-safe binary file format with write-ahead logging, structured memory, and concurrent I/O.

## Overview

WaxCore defines the `.mv2s` file format and provides the low-level primitives that every other Wax module builds upon. It handles:

- **Binary persistence** via a custom codec with dual-header mirroring and SHA-256 checksums
- **Write-ahead logging (WAL)** using a ring buffer for crash recovery and atomic commits
- **Frame storage** with support for compression (LZFSE, LZ4, Deflate), metadata, tags, and superseding relationships
- **Structured memory** through an entity-fact-predicate graph with temporal (bitemporal) queries
- **Concurrency** with actor isolation, async reader-writer locks, file locks, and a blocking I/O executor

The primary entry point is the ``Wax`` actor, which manages a single `.mv2s` file and exposes APIs for reading and writing frames, managing writer leases, and committing changes.

```swift
// Create a new memory store
let store = try await Wax.create(at: storeURL)

// Open an existing store
let store = try await Wax.open(at: storeURL)
```

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:FileFormat>

### Persistence

- ``Wax``
- ``WaxOptions``
- ``WaxStats``
- ``WaxWALStats``
- ``WaxError``

### File Format

- ``WaxHeaderPage``
- ``WaxFooter``
- ``WaxTOC``
- ``FrameMeta``
- ``FrameRole``
- ``FrameStatus``
- ``CanonicalEncoding``

### Write-Ahead Log

- <doc:WALAndCrashRecovery>
- ``WALRecord``
- ``WALEntry``
- ``WALFsyncPolicy``
- ``WALRingWriter``
- ``WALRingReader``

### Binary Codec

- ``BinaryEncoder``
- ``BinaryDecoder``
- ``BinaryEncodable``
- ``BinaryDecodable``

### Structured Memory

- <doc:StructuredMemory>
- ``EntityKey``
- ``PredicateKey``
- ``FactValue``
- ``StructuredFact``
- ``StructuredFactHit``
- ``StructuredFactsResult``
- ``StructuredEvidence``
- ``StructuredMemoryQueryContext``
- ``StructuredMemoryAsOf``

### Frame Operations

- ``PutFrame``
- ``DeleteFrame``
- ``SupersedeFrame``
- ``PutEmbedding``
- ``PendingEmbeddingSnapshot``

### Concurrency

- <doc:ConcurrencyModel>
- ``AsyncReadWriteLock``
- ``AsyncMutex``
- ``ReadWriteLock``
- ``UnfairLock``
- ``FileLock``
- ``BlockingIOExecutor``
- ``WaxWriterPolicy``

### I/O

- ``FDFile``

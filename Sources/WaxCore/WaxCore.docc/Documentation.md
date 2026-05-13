# ``WaxCore``

The foundational persistence layer for Wax: a crash-safe binary file format with write-ahead logging, structured memory, and concurrent I/O.

## Overview

WaxCore defines the `.wax` file format and provides the low-level primitives that every other Wax module builds upon. It handles:

- **Binary persistence** via a custom codec with dual-header mirroring and SHA-256 checksums
- **Write-ahead logging (WAL)** using a ring buffer for crash recovery and atomic commits
- **Frame storage** with support for compression (LZFSE, LZ4, Deflate), metadata, tags, and superseding relationships
- **Structured memory** through an entity-fact-predicate graph with temporal (bitemporal) queries
- **Concurrency** with actor isolation, async reader-writer locks, file locks, and a blocking I/O executor

WaxCore is an implementation module. The package-only ``Wax`` actor manages individual `.wax` files for other targets in this package, but it is not public API for downstream applications.

For app and package consumers, import the top-level `Wax` product and use the public orchestration APIs documented there. WaxCore documentation is most useful when you need to understand the file format, WAL behavior, structured-memory storage model, or concurrency primitives behind those public APIs.

> Note: the symbol topics below include internal/package symbols that DocC can render for package contributors. Their presence does not make the package-only ``Wax`` actor a public consumer surface.

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

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

Package-only implementation symbols are intentionally omitted from the public topic list below.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:FileFormat>
- ``WaxError``

### Write-Ahead Log

- <doc:WALAndCrashRecovery>

### Structured Memory

- <doc:StructuredMemory>

### Concurrency

- <doc:ConcurrencyModel>

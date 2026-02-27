---
sidebar_position: 2
title: "Wax File Format"
sidebar_label: "File Format"
---

Understand the binary layout of `.wax` files: dual headers, WAL ring buffer, TOC, and footer.

## Overview

The Wax format is a self-contained binary file designed for crash-safe, concurrent access. Every `.wax` file follows this layout:

```
Offset          Region              Size
──────          ──────              ────
0 KiB           Header Page A       4 KiB
4 KiB           Header Page B       4 KiB
8 KiB           WAL Ring Buffer     Configurable (default 256 MiB)
WAL + 8 KiB     Frame Payloads      Variable
After Payloads  TOC                 Variable
After TOC       Footer              64 bytes
```

## Magic Numbers

The format uses two magic values for identification:

| Magic | Bytes | Location |
|-------|-------|----------|
| `WAX1` | `0x57 0x41 0x58 0x31` | Header page offset 0 |
| `WAX1FOOT` | 8 bytes | Footer offset 0 |

The current spec version is **v1.0** (major=1, minor=0, packed as UInt16).

## Dual Header Pages

Two identical header pages at offsets 0 and 4 KiB provide crash-safe metadata updates. Each page contains:

| Offset | Type | Field |
|--------|------|-------|
| 0–3 | UInt32 | Magic (`WAX1`) |
| 4–5 | UInt16 | Format version |
| 6–7 | UInt8 x 2 | Spec major/minor |
| 8–15 | UInt64 | Header page generation |
| 16–23 | UInt64 | File generation |
| 24–31 | UInt64 | Footer offset |
| 32–39 | UInt64 | WAL offset |
| 40–47 | UInt64 | WAL size |
| 48–55 | UInt64 | WAL write position |
| 56–63 | UInt64 | WAL checkpoint position |
| 64–71 | UInt64 | WAL committed sequence |
| 72–103 | 32 bytes | TOC checksum (SHA-256) |
| 104–135 | 32 bytes | Header checksum (SHA-256) |
| 136–208 | 72 bytes | WAL replay snapshot (optional) |

### A/B Selection Strategy

On open, both header pages are read and validated. The page with the **highest `headerPageGeneration`** is selected, provided it has a valid magic number, supported format version, and correct checksum.

This ensures that a crash during a header write never corrupts the store — at worst, the previous header generation is used.

## WAL Ring Buffer

The WAL occupies a fixed-size region starting at offset 8 KiB. See [WAL & Crash Recovery](./wal-crash-recovery.md) for details on the ring buffer protocol, record format, and replay semantics.

## Table of Contents (TOC)

The TOC is a binary-encoded structure (via `BinaryEncoder`) containing:

- **`tocVersion`** (UInt64) — Currently version 1
- **`frames`** — Dense array of `FrameMeta` entries (frame IDs are sequential array indices)
- **`indexes`** — Index manifests for lexical and vector search segments
- **`timeIndex`** — Optional temporal index manifest
- **`segmentCatalog`** — Content segment catalog
- **`merkleRoot`** — 32-byte Merkle root for integrity verification
- **`tocChecksum`** — SHA-256 of the TOC body (excluding the final 32 checksum bytes, padded with 32 zero bytes)

## Footer

A fixed 64-byte footer at the end of the file:

| Offset | Type | Field |
|--------|------|-------|
| 0–7 | 8 bytes | Magic (`WAX1FOOT`) |
| 8–15 | UInt64 | TOC length |
| 16–47 | 32 bytes | TOC hash (SHA-256) |
| 48–55 | UInt64 | Generation |
| 56–63 | UInt64 | WAL committed sequence |

The footer's TOC hash must match the TOC's self-checksum for the file to be considered valid.

## Frame Metadata

Each frame stored in the TOC carries rich metadata via `FrameMeta`:

- **Identity**: `id`, `timestamp`, `anchorTs`, `uri`, `title`
- **Content**: `payloadOffset`, `payloadLength`, `canonicalEncoding`, `canonicalLength`
- **Integrity**: `checksum` (SHA-256 of canonical form), `storedChecksum`
- **Organization**: `kind`, `track`, `tags`, `labels`, `metadata` (string-to-string map)
- **Search**: `searchText`, `contentDates`
- **Relationships**: `role` (document/chunk/blob/system), `parentId`, `supersedes`, `supersededBy`
- **Chunking**: `chunkIndex`, `chunkCount`, `chunkManifest`
- **Status**: `active` or `deleted`

## Compression

Frame payloads support four encoding strategies via `CanonicalEncoding`:

| Encoding | Description |
|----------|-------------|
| `plain` | No compression |
| `lzfse` | Apple's LZFSE (best ratio on Apple platforms) |
| `lz4` | Fast compression/decompression |
| `deflate` | Widely compatible zlib deflate |

## Constants and Limits

| Constant | Value |
|----------|-------|
| Header page size | 4 KiB |
| Header region (A+B) | 8 KiB |
| Footer size | 64 bytes |
| WAL record header | 48 bytes |
| Default WAL size | 256 MiB |
| Max string bytes | 16 MiB |
| Max blob bytes | 256 MiB |
| Max array count | 10,000,000 |
| Max TOC bytes | 64 MiB |

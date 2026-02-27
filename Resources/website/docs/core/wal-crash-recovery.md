---
sidebar_position: 3
title: "WAL & Crash Recovery"
sidebar_label: "WAL & Crash Recovery"
---

How the write-ahead log ring buffer ensures durability and enables crash recovery.

## Overview

The WAL (Write-Ahead Log) is a fixed-size circular ring buffer that records all mutations before they are committed to the main file structure. This design ensures that:

1. A crash at any point never corrupts the store
2. Uncommitted mutations are automatically replayed on next open
3. Writes can be batched for performance without sacrificing durability

## Ring Buffer Architecture

The WAL occupies a contiguous region starting at file offset 8 KiB. Its default size is 256 MiB, configurable at creation time. The ring buffer uses two pointers:

- **Write position** — where the next record will be written
- **Checkpoint position** — the boundary of committed records

Records between the checkpoint and write positions are **pending** (uncommitted). On commit, the checkpoint advances to match the write position.

## WAL Records

Each WAL record has a 48-byte header:

| Offset | Type | Field |
|--------|------|-------|
| 0–7 | UInt64 | Sequence number (monotonically increasing) |
| 8–11 | UInt32 | Payload length |
| 12–15 | UInt32 | Flags (bit 0 = isPadding) |
| 16–47 | 32 bytes | Payload checksum (SHA-256) |

Records come in three types:

- **Data** — Contains a mutation payload (frame put, delete, supersede, or embedding) with a SHA-256 checksum
- **Padding** — Fills gaps when there isn't enough space at the ring's end for a new record; the ring wraps around
- **Sentinel** — All-zero marker indicating the end of valid records

## WAL Entries

Each data record's payload encodes a `WALEntry` with an opcode:

| Opcode | Entry | Description |
|--------|-------|-------------|
| `0x01` | `putFrame` | Store frame metadata and payload reference |
| `0x02` | `deleteFrame` | Mark a frame as deleted |
| `0x03` | `supersedeFrame` | Link an older frame to its replacement |
| `0x04` | `putEmbedding` | Store a vector embedding for a frame |

## Fsync Policies

The `WALFsyncPolicy` controls when writes are flushed to disk:

| Policy | Behavior |
|--------|----------|
| `.always` | Fsync after every write (safest, slowest) |
| `.onCommit` | Fsync only when the WAL is checkpointed |
| `.everyBytes(threshold)` | Fsync after accumulating a threshold of bytes |

Choose based on your durability requirements. `.everyBytes(1_048_576)` (1 MiB) is a good balance for most applications.

## Crash Recovery

When opening a store, WaxCore performs the following recovery sequence:

1. **Header A/B selection** — Both header pages are read and validated. The page with the highest `headerPageGeneration` that passes checksum validation is selected.

2. **Replay snapshot check** — If the selected header contains a valid WAL replay snapshot (magic `WALSNAP1` at offset 136), recovery can skip already-committed WAL records and resume from the snapshot's position. This significantly speeds up recovery for large WAL buffers.

3. **WAL scan** — Starting from the checkpoint position, the `WALRingReader` scans forward through the ring buffer, reading all pending (uncommitted) records. Corrupted records in the pending region are tolerated — scanning continues for position tracking.

4. **State reconstruction** — Pending mutations are applied to rebuild in-memory indexes and frame metadata.

## Proactive Commit

WaxCore supports proactive commit thresholds to bound the amount of data at risk in the WAL:

```swift
let options = WaxOptions(
    proactiveCommitThreshold: 1024  // Auto-commit after 1024 pending entries
)
```

When the pending entry count exceeds this threshold, a commit is triggered automatically during the next write operation.

## Replay State Snapshots

When `enableReplayStateSnapshot` is set in `WaxOptions`, the header stores a snapshot of the WAL state at the last commit. This snapshot includes:

- File generation
- Committed sequence number
- Footer offset
- Write and checkpoint positions
- Pending byte count
- Last sequence number

On recovery, this snapshot allows the reader to skip the committed portion of the WAL and start scanning from the snapshot's position, reducing recovery time from O(WAL size) to O(pending bytes).

## Checksum Verification

Every layer of the persistence stack uses SHA-256 checksums:

- **WAL records** — SHA-256 of the payload bytes
- **Header pages** — SHA-256 of the header with the checksum field zeroed
- **TOC** — SHA-256 of the TOC body, excluding the final 32 bytes, padded with 32 zero bytes
- **Footer** — Validates that the TOC hash matches

This multi-layer checksum strategy ensures that corruption is detected at every level.

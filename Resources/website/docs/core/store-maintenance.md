---
sidebar_position: 2
title: "Store maintenance"
sidebar_label: "Store maintenance"
---

# Store maintenance

`wax-cli` provides two offline repair commands for a store with stale or
missing vectors. Both commands are copy-first: they snapshot the source under
an advisory read lock, work in a sibling staging file, run deep verification,
and atomically publish the requested output. A successful operation leaves the
source file unchanged.

## Compact a store

Compaction rewrites committed frames and drops payloads that are no longer
live. It also sizes the destination WAL from encoded frame metadata and payload
requirements.

```bash
wax-cli compact-store \
  --direct-store \
  --no-embedder \
  --store-path /path/to/source.wax \
  --output /path/to/compacted.wax
```

`--direct-store`, `--store-path`, and `--output` are required. Add
`--overwrite` to replace an existing destination. Existing destinations must
be regular, unlocked files; directories, symlinks, hard-link aliases, and the
broker-managed live store are refused.

## Backfill missing vectors

Backfill embeds live searchable frames that have no vector on a verified copy.
It is idempotent and requires a build with an embedding provider (for example,
the `MiniLMEmbeddings` trait).

```bash
wax-cli embed-backfill \
  --direct-store \
  --store-path /path/to/source.wax \
  --output /path/to/backfilled.wax
```

The command also requires `--direct-store` and `--output`; `--no-embedder`
fails closed. Use `--overwrite` only for an intentional replacement. JSON
output includes the examined/embedded counts, remaining `framesWithoutVectors`,
`sourceUnchanged`, and `deepVerified` fields:

```bash
wax-cli embed-backfill --direct-store \
  --store-path /path/to/source.wax \
  --output /path/to/backfilled.wax --format json
```

These commands are operator tools, not a substitute for the broker's normal
shared live-store flow. Stop attached writers before repair; the advisory lock
probe cannot prevent an unrelated process from swapping a pathname after the
probe, so Wax rechecks path type and file identity immediately before
promotion and fails closed during rollback if the destination has changed.

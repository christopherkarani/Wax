# Getting Started with WaxCore

Understand the `.wax` persistence layer without depending on package-only storage actors.

## Overview

WaxCore is the persistence foundation for all Wax modules. Text indexing, vector search, and structured memory ultimately store data as **frames** inside `.wax` files, but the package-only ``Wax`` actor that coordinates those files is not public API.

For downstream application code, import the top-level `Wax` product and use the public orchestration APIs there. Use this article as contributor-oriented context for the lower-level storage behavior behind those APIs.

## Package Boundary

Direct store creation, opening, writer leases, frame writes, payload reads, commits, and close operations are implemented behind package access control. Public docs should not teach consumers to call those internals directly.

Inside the package, store creation can tune the WAL ring buffer and replay behavior with options such as `walFsyncPolicy:` and `walReplayStateSnapshotEnabled:`. Those labels are documented here to explain the implementation contract, not to advertise a public initializer.

## Storage Lifecycle

The package-only store lifecycle has four conceptual phases:

1. Create or open a `.wax` file and replay any pending WAL records.
2. Acquire exclusive write ownership before mutating frame state.
3. Append frame mutations through the WAL and commit them into the table of contents and footer.
4. Release resources after outstanding reads and writes complete.

Each phase is exposed to public consumers through higher-level Wax APIs rather than through the package-only ``Wax`` actor.

## Writing Frames

Frames are the durable records in a `.wax` file. A frame can carry payload bytes, metadata, tags, status, and superseding relationships. Mutations are first staged in the WAL so crash recovery can replay or discard incomplete work deterministically.

## Reading Frames

Committed frame metadata is indexed by frame ID in the table of contents. Payload reads use the stored payload offset and length, while higher-level modules decide how to interpret text, embeddings, structured facts, or media-derived records.

## Committing Changes

Commits flush staged WAL mutations, persist the updated table of contents and footer, and update the mirrored header state. Until a commit completes, recovery treats staged records as replay input rather than as fully committed state.

## Closing the Store

Package code closes stores when a subsystem is done with the file so file descriptors, locks, and pending I/O work are released cleanly. Public consumers normally reach that behavior through orchestrator lifecycle methods in the top-level `Wax` module.

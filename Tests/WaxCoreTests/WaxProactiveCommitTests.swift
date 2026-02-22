import Foundation
import Testing
@testable import WaxCore

// MARK: - Sizing helpers

/// Returns a WAL size (in bytes) that can hold exactly `capacity` WAL entries whose
/// WALEntryCodec-encoded payload fits within `payloadSize` bytes each.
///
/// The ring writer needs an extra sentinel slot after the last entry, so we add one
/// extra `entrySize` as headroom.
private func walSizeForEntries(_ capacity: Int, payloadSize: Int) throws -> UInt64 {
    // Encode a representative entry to measure the real WALEntryCodec payload size.
    let entrySize = UInt64(WALRecord.headerSize) + UInt64(payloadSize)
    return entrySize * UInt64(capacity + 1) // +1 for sentinel slot headroom
}

// MARK: - Writer lease: basic acquire/release

@Test func writerLeaseAcquireAndReleaseRoundTrip() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)

    let lease = try await wax.acquireWriterLease(policy: .fail)
    // A second UUID-typed value means the lease was granted.
    #expect(lease != UUID(uuidString: "00000000-0000-0000-0000-000000000000"))

    // After releasing, acquiring again must succeed immediately.
    await wax.releaseWriterLease(lease)
    let lease2 = try await wax.acquireWriterLease(policy: .fail)
    #expect(lease2 != lease)
    await wax.releaseWriterLease(lease2)

    try await wax.close()
}

// MARK: - Writer lease: .fail policy rejects second acquirer

@Test func writerLeaseFailPolicyThrowsWhenHeld() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)

    let lease = try await wax.acquireWriterLease(policy: .fail)

    do {
        _ = try await wax.acquireWriterLease(policy: .fail)
        Issue.record("Expected writerBusy error but no error was thrown")
    } catch let error as WaxError {
        guard case .writerBusy = error else {
            Issue.record("Expected WaxError.writerBusy, got \(error)")
            return
        }
    }

    await wax.releaseWriterLease(lease)
    try await wax.close()
}

// MARK: - Writer lease: .fail policy does not affect a fresh store (no current holder)

@Test func writerLeaseFailPolicySucceedsWhenNoHolder() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)

    // No one holds the lease, so .fail must succeed.
    let lease = try await wax.acquireWriterLease(policy: .fail)
    #expect(lease != UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
    await wax.releaseWriterLease(lease)
    try await wax.close()
}

// MARK: - Writer lease: .wait policy is unblocked when holder releases

@Test func writerLeaseWaitPolicyUnblockedOnRelease() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)

    let firstLease = try await wax.acquireWriterLease(policy: .fail)

    // Launch a task that will wait for the lease.
    let waiterTask = Task {
        try await wax.acquireWriterLease(policy: .wait)
    }

    // Yield so the waiter task has a chance to enqueue itself.
    try await Task.sleep(for: .milliseconds(20))

    // Release: the waiter should be woken and receive a new lease ID.
    await wax.releaseWriterLease(firstLease)

    let secondLease = try await waiterTask.value
    #expect(secondLease != firstLease)

    await wax.releaseWriterLease(secondLease)
    try await wax.close()
}

// MARK: - Writer lease: .timeout policy expires when holder never releases

@Test func writerLeaseTimeoutPolicyExpiresUnderContention() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)

    let blocker = try await wax.acquireWriterLease(policy: .fail)

    do {
        // 50 ms timeout — short enough to make the test fast, long enough to be reliable.
        _ = try await wax.acquireWriterLease(policy: .timeout(.milliseconds(50)))
        Issue.record("Expected writerTimeout error but no error was thrown")
    } catch let error as WaxError {
        guard case .writerTimeout = error else {
            Issue.record("Expected WaxError.writerTimeout, got \(error)")
            await wax.releaseWriterLease(blocker)
            try await wax.close()
            return
        }
    }

    await wax.releaseWriterLease(blocker)
    try await wax.close()
}

// MARK: - Writer lease: .timeout policy succeeds when holder releases in time

@Test func writerLeaseTimeoutPolicySucceedsWhenReleasedBeforeDeadline() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)

    let firstLease = try await wax.acquireWriterLease(policy: .fail)

    let waiterTask = Task {
        // 500 ms — the holder will release well within this window.
        try await wax.acquireWriterLease(policy: .timeout(.milliseconds(500)))
    }

    // Release quickly (20 ms) — well before the 500 ms deadline.
    try await Task.sleep(for: .milliseconds(20))
    await wax.releaseWriterLease(firstLease)

    let secondLease = try await waiterTask.value
    #expect(secondLease != firstLease)
    await wax.releaseWriterLease(secondLease)
    try await wax.close()
}

// MARK: - Writer lease: releasing with a wrong UUID is a no-op

@Test func writerLeaseReleaseWithWrongUUIDIsNoOp() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)

    let lease = try await wax.acquireWriterLease(policy: .fail)

    // Releasing with a different UUID must leave the lease intact.
    await wax.releaseWriterLease(UUID())

    // The original holder is still active; .fail must still reject a second attempt.
    do {
        _ = try await wax.acquireWriterLease(policy: .fail)
        Issue.record("Expected writerBusy error after no-op release")
    } catch let error as WaxError {
        guard case .writerBusy = error else {
            Issue.record("Expected WaxError.writerBusy, got \(error)")
            return
        }
    }

    await wax.releaseWriterLease(lease)
    try await wax.close()
}

// MARK: - Writer lease: sequential acquisition after release is stable

@Test func writerLeaseSequentialAcquireReleaseIsStable() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)

    var previousLease = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    for _ in 0..<10 {
        let lease = try await wax.acquireWriterLease(policy: .fail)
        #expect(lease != previousLease)
        previousLease = lease
        await wax.releaseWriterLease(lease)
    }

    try await wax.close()
}

// MARK: - WAL capacity: auto-commit on capacity exhaustion

@Test func walCapacityAutoCommitOnExhaustion() async throws {
    // Create a store whose WAL holds exactly two entries, then attempt a third put.
    // The third put must trigger an implicit commit (auto-commit) and succeed.
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    // Measure actual WAL payload for a minimal put entry.
    let sampleOptions = FrameMetaSubset()
    let samplePut = PutFrame(
        frameId: 0,
        timestampMs: 0,
        options: sampleOptions,
        payloadOffset: 0,
        payloadLength: 1,
        canonicalEncoding: .plain,
        canonicalLength: 1,
        canonicalChecksum: Data(repeating: 0xAA, count: 32),
        storedChecksum: Data(repeating: 0xBB, count: 32)
    )
    let payloadSize = try WALEntryCodec.encode(.putFrame(samplePut)).count
    let walSize = try walSizeForEntries(2, payloadSize: payloadSize)

    // Use options that disable proactive commit so we exercise the reactive path.
    let options = WaxOptions(
        walFsyncPolicy: .onCommit,
        walProactiveCommitThresholdPercent: nil,
        walProactiveCommitMaxWalSizeBytes: nil,
        walProactiveCommitMinPendingBytes: 1
    )

    let wax = try await Wax.create(at: url, walSize: walSize, options: options)

    _ = try await wax.put(Data([0x01]))
    _ = try await wax.put(Data([0x02]))

    // Third put exceeds WAL capacity; the store must auto-commit and then accept the write.
    _ = try await wax.put(Data([0x03]))

    let walStatsAfter = await wax.walStats()
    #expect(walStatsAfter.autoCommitCount >= 1)

    let statsAfter = await wax.stats()
    // After auto-commit the previous frames become committed.
    #expect(statsAfter.frameCount >= 2)

    try await wax.close()
}

// MARK: - WAL capacity: single frame too large for WAL throws capacityExceeded

@Test func walCapacityFrameTooLargeForWalThrows() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    // Tiny WAL: just large enough for the header record overhead but not a real payload.
    // walRecordHeaderSize is 48 bytes; a put entry WAL payload is larger than 48 bytes.
    // Use the absolute minimum: Constants.walRecordHeaderSize as walSize. The put will
    // produce a WALEntryCodec payload larger than that, so it must be rejected.
    let walSize = Constants.walRecordHeaderSize * 2

    let wax = try await Wax.create(at: url, walSize: walSize)

    do {
        // Any non-trivial content will produce a WAL entry larger than the tiny WAL.
        _ = try await wax.put(Data(repeating: 0xAB, count: 64))
        Issue.record("Expected capacityExceeded error for oversized frame")
    } catch let error as WaxError {
        switch error {
        case .capacityExceeded:
            break // Correct outcome.
        default:
            Issue.record("Expected WaxError.capacityExceeded, got \(error)")
        }
    }

    try await wax.close()
}

// MARK: - Proactive auto-commit: triggers before WAL is full

@Test func proactiveAutoCommitTriggersBeforeCapacityEdge() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    // A 64 KiB WAL with a very low proactive threshold (10%) and a tiny min-pending
    // requirement so that even a handful of entries cross the threshold.
    let walSize: UInt64 = 64 * 1024
    let wax = try await Wax.create(
        at: url,
        walSize: walSize,
        options: WaxOptions(
            walFsyncPolicy: .onCommit,
            walProactiveCommitThresholdPercent: 10,
            walProactiveCommitMaxWalSizeBytes: nil,
            walProactiveCommitMinPendingBytes: 1
        )
    )

    // Write enough data to cross the 10% threshold (6.4 KiB).
    for i in 0..<100 {
        _ = try await wax.put(
            Data(repeating: UInt8(i % 251), count: 128),
            options: FrameMetaSubset(searchText: "proactive-\(i)")
        )
    }

    let stats = await wax.walStats()
    // Proactive commits must have fired.
    #expect(stats.autoCommitCount > 0)
    #expect(stats.checkpointCount > 0)
    // Pending bytes after proactive commit must be within the WAL bound.
    #expect(stats.pendingBytes <= stats.walSize)

    try await wax.close()
}

// MARK: - Proactive auto-commit: respects walProactiveCommitMaxWalSizeBytes gate

@Test func proactiveAutoCommitDisabledForLargeWal() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    // maxWalSizeBytes smaller than walSize: proactive commit must be suppressed.
    let walSize: UInt64 = 1 * 1024 * 1024 // 1 MiB
    let wax = try await Wax.create(
        at: url,
        walSize: walSize,
        options: WaxOptions(
            walFsyncPolicy: .onCommit,
            walProactiveCommitThresholdPercent: 50,
            walProactiveCommitMaxWalSizeBytes: 512 * 1024, // 512 KiB — smaller than walSize
            walProactiveCommitMinPendingBytes: 1
        )
    )

    for i in 0..<200 {
        _ = try await wax.put(
            Data(repeating: UInt8(i % 251), count: 256),
            options: FrameMetaSubset(searchText: "large-wal-\(i)")
        )
    }

    let stats = await wax.walStats()
    // The gate (walSize > maxWalSizeBytes) must suppress proactive commits entirely.
    #expect(stats.autoCommitCount == 0)

    try await wax.close()
}

// MARK: - Proactive auto-commit: disabled when threshold is nil

@Test func proactiveAutoCommitDisabledWhenThresholdIsNil() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(
        at: url,
        walSize: 128 * 1024,
        options: WaxOptions(walProactiveCommitThresholdPercent: nil)
    )

    for i in 0..<200 {
        _ = try await wax.put(
            Data(repeating: UInt8(i % 251), count: 128),
            options: FrameMetaSubset(searchText: "nil-threshold-\(i)")
        )
    }

    let stats = await wax.walStats()
    #expect(stats.autoCommitCount == 0)
    #expect(stats.checkpointCount == 0)

    try await wax.close()
}

// MARK: - Proactive auto-commit: minPendingBytes gate prevents premature commits

@Test func proactiveAutoCommitRespectsMinPendingBytesGate() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    // Set minPendingBytes to a value that requires many writes to accumulate.
    let walSize: UInt64 = 256 * 1024
    let minPending: UInt64 = 200 * 1024 // 200 KiB — very high relative to individual writes
    let wax = try await Wax.create(
        at: url,
        walSize: walSize,
        options: WaxOptions(
            walFsyncPolicy: .onCommit,
            walProactiveCommitThresholdPercent: 10,
            walProactiveCommitMaxWalSizeBytes: nil,
            walProactiveCommitMinPendingBytes: minPending
        )
    )

    // Write 50 small frames — unlikely to accumulate 200 KiB in pending WAL bytes.
    for i in 0..<50 {
        _ = try await wax.put(
            Data(repeating: UInt8(i % 251), count: 64),
            options: FrameMetaSubset(searchText: "min-pending-\(i)")
        )
    }

    let stats = await wax.walStats()
    // The minPendingBytes gate should have suppressed all proactive commits.
    #expect(stats.autoCommitCount == 0)

    try await wax.close()
}

// MARK: - WAL stats: autoCommitCount increments on each implicit commit

@Test func walStatsAutoCommitCountIncrements() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    // Small WAL that requires multiple commits during sustained writes.
    let wax = try await Wax.create(
        at: url,
        walSize: 2 * 1024,
        options: WaxOptions(
            walFsyncPolicy: .onCommit,
            walProactiveCommitThresholdPercent: nil, // Disable proactive; exercise reactive path.
            walProactiveCommitMaxWalSizeBytes: nil,
            walProactiveCommitMinPendingBytes: 1
        )
    )

    var maxAutoCommitCount: UInt64 = 0
    for i in 0..<200 {
        _ = try await wax.put(
            Data(repeating: UInt8(i % 251), count: 64),
            options: FrameMetaSubset(searchText: "count-\(i)")
        )
        let s = await wax.walStats()
        if s.autoCommitCount > maxAutoCommitCount {
            maxAutoCommitCount = s.autoCommitCount
        }
    }

    #expect(maxAutoCommitCount > 0)

    let finalStats = await wax.walStats()
    #expect(finalStats.autoCommitCount > 0)
    #expect(finalStats.checkpointCount >= finalStats.autoCommitCount)

    try await wax.close()
}

// MARK: - WAL stats: pendingBytes resets to zero after explicit commit

@Test func walStatsPendingBytesResetAfterExplicitCommit() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url, walSize: 256 * 1024)

    _ = try await wax.put(Data("pending-frame".utf8))
    let beforeCommit = await wax.walStats()
    #expect(beforeCommit.pendingBytes > 0)

    try await wax.commit()
    let afterCommit = await wax.walStats()
    #expect(afterCommit.pendingBytes == 0)
    #expect(afterCommit.checkpointCount == 1)
    #expect(afterCommit.committedSeq > 0)

    try await wax.close()
}

// MARK: - WAL stats: lastSeq is always >= committedSeq

@Test func walStatsLastSeqAlwaysAtLeastCommittedSeq() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url, walSize: 64 * 1024)

    for i in 0..<20 {
        _ = try await wax.put(
            Data(repeating: UInt8(i), count: 32),
            options: FrameMetaSubset(searchText: "seq-check-\(i)")
        )
        let s = await wax.walStats()
        #expect(s.lastSeq >= s.committedSeq)
    }

    try await wax.commit()

    let final = await wax.walStats()
    #expect(final.lastSeq >= final.committedSeq)
    #expect(final.pendingBytes == 0)

    try await wax.close()
}

// MARK: - putBatch: falls back to sequential append when batch overflows WAL

@Test func putBatchFallsBackToSequentialOnCapacityOverflow() async throws {
    // Size the WAL so the entire batch cannot fit atomically, forcing sequential fallback.
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let sampleOptions = FrameMetaSubset()
    let samplePut = PutFrame(
        frameId: 0,
        timestampMs: 0,
        options: sampleOptions,
        payloadOffset: 0,
        payloadLength: 1,
        canonicalEncoding: .plain,
        canonicalLength: 1,
        canonicalChecksum: Data(repeating: 0xAA, count: 32),
        storedChecksum: Data(repeating: 0xBB, count: 32)
    )
    let payloadSize = try WALEntryCodec.encode(.putFrame(samplePut)).count
    // WAL holds exactly 3 entries — the batch below has 5.
    let walSize = try walSizeForEntries(3, payloadSize: payloadSize)

    let wax = try await Wax.create(
        at: url,
        walSize: walSize,
        options: WaxOptions(
            walFsyncPolicy: .onCommit,
            walProactiveCommitThresholdPercent: nil,
            walProactiveCommitMaxWalSizeBytes: nil,
            walProactiveCommitMinPendingBytes: 1
        )
    )

    let contents: [Data] = (0..<5).map { Data([UInt8($0)]) }
    let opts: [FrameMetaSubset] = (0..<5).map { FrameMetaSubset(searchText: "batch-\($0)") }

    let frameIds = try await wax.putBatch(contents, options: opts)
    #expect(frameIds.count == 5)
    #expect(frameIds == [0, 1, 2, 3, 4])

    // Sequential fallback triggers commits; at least some frames must be committed.
    let stats = await wax.stats()
    let walStats = await wax.walStats()
    #expect(stats.frameCount + stats.pendingFrames == 5)
    // Auto-commits must have fired to accommodate all 5 frames in a 3-capacity WAL.
    #expect(walStats.autoCommitCount >= 1)

    try await wax.close()
}

// MARK: - Multiple put/commit cycles with tiny WAL

@Test func multipleCommitCyclesWithTinyWal() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let sampleOptions = FrameMetaSubset()
    let samplePut = PutFrame(
        frameId: 0,
        timestampMs: 0,
        options: sampleOptions,
        payloadOffset: 0,
        payloadLength: 1,
        canonicalEncoding: .plain,
        canonicalLength: 1,
        canonicalChecksum: Data(repeating: 0xAA, count: 32),
        storedChecksum: Data(repeating: 0xBB, count: 32)
    )
    let payloadSize = try WALEntryCodec.encode(.putFrame(samplePut)).count
    // WAL fits exactly 2 entries — force a commit after every 2 puts.
    let walSize = try walSizeForEntries(2, payloadSize: payloadSize)

    let wax = try await Wax.create(
        at: url,
        walSize: walSize,
        options: WaxOptions(
            walFsyncPolicy: .onCommit,
            walProactiveCommitThresholdPercent: nil,
            walProactiveCommitMaxWalSizeBytes: nil,
            walProactiveCommitMinPendingBytes: 1
        )
    )

    // Write 10 frames — each pair will auto-commit, generating 5 commit cycles.
    let totalFrames = 10
    for i in 0..<totalFrames {
        _ = try await wax.put(Data([UInt8(i)]))
    }

    let walStats = await wax.walStats()
    #expect(walStats.autoCommitCount >= 4) // At minimum 4 auto-commits for 10 frames in a 2-slot WAL.

    // Close commits whatever remains pending.
    try await wax.close()

    // Reopen and verify all frames survived.
    let reopened = try await Wax.open(at: url)
    let finalStats = await reopened.stats()
    #expect(finalStats.frameCount == UInt64(totalFrames))
    #expect(finalStats.pendingFrames == 0)
    try await reopened.close()
}

// MARK: - WAL stats: wrapCount increments on ring wrap

@Test func walStatsWrapCountIncrements() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    // Use an intentionally small WAL to provoke wrapping behaviour.
    let wax = try await Wax.create(
        at: url,
        walSize: 2 * 1024,
        options: WaxOptions(
            walFsyncPolicy: .onCommit,
            walProactiveCommitThresholdPercent: nil,
            walProactiveCommitMaxWalSizeBytes: nil,
            walProactiveCommitMinPendingBytes: 1
        )
    )

    for i in 0..<100 {
        _ = try await wax.put(
            Data(repeating: UInt8(i % 251), count: 64),
            options: FrameMetaSubset(searchText: "wrap-\(i)")
        )
    }

    let stats = await wax.walStats()
    // wrapCount is maintained by WALRingWriter; at least one wrap must have occurred.
    #expect(stats.wrapCount >= 1)

    try await wax.close()
}

// MARK: - WAL stats: writePos stays within walSize bounds

@Test func walStatsWritePosNeverExceedsWalSize() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let walSize: UInt64 = 4 * 1024
    let wax = try await Wax.create(
        at: url,
        walSize: walSize,
        options: WaxOptions(
            walFsyncPolicy: .onCommit,
            walProactiveCommitThresholdPercent: nil,
            walProactiveCommitMaxWalSizeBytes: nil,
            walProactiveCommitMinPendingBytes: 1
        )
    )

    for i in 0..<150 {
        _ = try await wax.put(
            Data(repeating: UInt8(i % 251), count: 48),
            options: FrameMetaSubset(searchText: "bounds-\(i)")
        )
        let s = await wax.walStats()
        #expect(s.writePos < s.walSize)
        #expect(s.checkpointPos < s.walSize)
        #expect(s.pendingBytes <= s.walSize)
    }

    try await wax.close()
}

// MARK: - Proactive auto-commit: walSize is correctly reported in stats

@Test func walStatsReportCorrectWalSize() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let expectedWalSize: UInt64 = 128 * 1024
    let wax = try await Wax.create(at: url, walSize: expectedWalSize)

    let stats = await wax.walStats()
    #expect(stats.walSize == expectedWalSize)

    try await wax.close()
}

// MARK: - delete entries also trigger capacity-based auto-commit

@Test func deleteEntriesAlsoTriggerAutoCommitOnCapacityPressure() async throws {
    // Strategy:
    //   1. Compute WAL sizes for a put entry and a delete entry separately.
    //   2. Create a store with a WAL large enough for 1 put entry but only 2 delete
    //      entries, so that the third delete (after the frames are committed) forces
    //      a reactive auto-commit through the ensureWalCapacityLocked path.

    // Measure the real WAL payload sizes for put and delete entries.
    let sampleOptions = FrameMetaSubset()
    let samplePut = PutFrame(
        frameId: 0,
        timestampMs: 0,
        options: sampleOptions,
        payloadOffset: 0,
        payloadLength: 1,
        canonicalEncoding: .plain,
        canonicalLength: 1,
        canonicalChecksum: Data(repeating: 0xAA, count: 32),
        storedChecksum: Data(repeating: 0xBB, count: 32)
    )
    let putPayloadSize = try WALEntryCodec.encode(.putFrame(samplePut)).count
    let deletePayloadSize = try WALEntryCodec.encode(.deleteFrame(DeleteFrame(frameId: 0))).count

    // A put entry is always larger than a delete entry; use the put size to drive WAL
    // sizing. We want exactly 1 put entry to fit (for the initial commit), then reuse
    // the same WAL — after commit, pendingBytes resets, and we need only 2 delete
    // entries to fit before the third triggers an auto-commit.
    //
    // Size = 1 put slot + 2 delete slots + 1 extra sentinel slot.
    let putEntrySize = UInt64(WALRecord.headerSize) + UInt64(putPayloadSize)
    let deleteEntrySize = UInt64(WALRecord.headerSize) + UInt64(deletePayloadSize)
    let walSize = putEntrySize + (deleteEntrySize * 3) // 1 put + 2 deletes + 1 sentinel

    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(
        at: url,
        walSize: walSize,
        options: WaxOptions(
            walFsyncPolicy: .onCommit,
            walProactiveCommitThresholdPercent: nil,
            walProactiveCommitMaxWalSizeBytes: nil,
            walProactiveCommitMinPendingBytes: 1
        )
    )

    // Write and commit a single frame so frame 0 exists in the TOC.
    _ = try await wax.put(Data([0x01]))
    try await wax.commit()

    // Write and commit a second frame (auto-commit will fire since WAL is now full for puts).
    // We use individual commits to keep each put within the WAL.
    _ = try await wax.put(Data([0x02]))
    try await wax.commit()

    _ = try await wax.put(Data([0x03]))
    try await wax.commit()

    let autoCommitsAfterPuts = (await wax.walStats()).autoCommitCount

    // Now issue three deletes. The WAL can hold 2 delete entries at a time;
    // the third must trigger a reactive auto-commit.
    try await wax.delete(frameId: 0)
    try await wax.delete(frameId: 1)
    try await wax.delete(frameId: 2)

    let finalStats = await wax.walStats()
    #expect(finalStats.autoCommitCount > autoCommitsAfterPuts)

    try await wax.close()
}

// MARK: - Proactive auto-commit: overflow in estimated bytes still triggers commit

@Test func proactiveAutoCommitHandlesNormalEstimatedBytesGracefully() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    // Use a very tight threshold (1%) with a large payload to aggressively trigger proactive commits.
    let walSize: UInt64 = 32 * 1024
    let wax = try await Wax.create(
        at: url,
        walSize: walSize,
        options: WaxOptions(
            walFsyncPolicy: .onCommit,
            walProactiveCommitThresholdPercent: 1,
            walProactiveCommitMaxWalSizeBytes: nil,
            walProactiveCommitMinPendingBytes: 1
        )
    )

    // Write 50 frames with modest payload; the 1% threshold is ~327 bytes which is hit fast.
    for i in 0..<50 {
        _ = try await wax.put(
            Data(repeating: UInt8(i % 251), count: 256),
            options: FrameMetaSubset(searchText: "overflow-probe-\(i)")
        )
    }

    let stats = await wax.walStats()
    #expect(stats.autoCommitCount > 0)
    #expect(stats.pendingBytes <= stats.walSize)

    try await wax.close()
}

// MARK: - WAL stats: checkpointCount equals number of commits

@Test func walStatsCheckpointCountMatchesExplicitCommitCount() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url, walSize: 256 * 1024)

    for i in 0..<5 {
        _ = try await wax.put(
            Data(repeating: UInt8(i), count: 32),
            options: FrameMetaSubset(searchText: "commit-count-\(i)")
        )
        try await wax.commit()
    }

    let stats = await wax.walStats()
    #expect(stats.checkpointCount == 5)
    #expect(stats.autoCommitCount == 0)

    try await wax.close()
}

// MARK: - WAL stats: no-op commit does not increment checkpointCount

@Test func walStatsNoOpCommitDoesNotIncrementCheckpoint() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url, walSize: 256 * 1024)

    // A commit with no pending mutations is a no-op.
    try await wax.commit()
    let stats = await wax.walStats()
    #expect(stats.checkpointCount == 0)
    #expect(stats.autoCommitCount == 0)
    #expect(stats.pendingBytes == 0)

    try await wax.close()
}

// MARK: - Writer lease: concurrent multiple waiters are served in FIFO order

@Test func writerLeaseConcurrentWaitersServedInOrder() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)

    let firstLease = try await wax.acquireWriterLease(policy: .fail)

    // Enqueue two waiters back-to-back.
    let waiter1 = Task { try await wax.acquireWriterLease(policy: .wait) }
    let waiter2 = Task { try await wax.acquireWriterLease(policy: .wait) }

    // Let both waiters enqueue themselves.
    try await Task.sleep(for: .milliseconds(30))

    // Release the first holder — waiter1 should be unblocked first.
    await wax.releaseWriterLease(firstLease)

    let lease1 = try await waiter1.value
    // Release waiter1 — waiter2 is next.
    await wax.releaseWriterLease(lease1)

    let lease2 = try await waiter2.value
    #expect(lease2 != lease1)
    #expect(lease2 != firstLease)

    await wax.releaseWriterLease(lease2)
    try await wax.close()
}

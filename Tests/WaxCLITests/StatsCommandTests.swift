import Testing
@testable import WaxCore
@testable import wax_cli

/// Every open moves the WAL's last sequence far past the committed one (the replay sequence
/// floor), so the text summary must not present the two as a range of pending records.
@Test func statsWALSummaryShowsSequencesSeparatelyFromPendingWork() {
    let wal = WaxWALStats(
        walSize: 8 * 1024 * 1024,
        writePos: 4096,
        checkpointPos: 4096,
        pendingBytes: 0,
        committedSeq: 12,
        lastSeq: 174_775,
        wrapCount: 0,
        checkpointCount: 1,
        sentinelWriteCount: 1,
        writeCallCount: 1,
        autoCommitCount: 0,
        replaySnapshotHitCount: 0,
        replayTruncationCount: 0,
        replayFooterScanCount: 0
    )
    let summary = StatsCommand.walSummary(wal)
    #expect(summary == "WAL: 0 bytes pending (committed seq 12, last seq 174775)")
    #expect(!summary.contains("12-174775"))
}

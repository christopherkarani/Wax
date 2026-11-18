import Foundation
import Testing
@testable import Wax
@testable import WaxCore

/// Appends one uncommitted put whose data payload is torn, as a crash under `.onCommit` fsync can leave.
private func appendTornPendingPut(to url: URL) throws {
    let file = try FDFile.open(at: url)
    defer { try? file.close() }
    let pageA = try file.readExactly(length: Int(Constants.headerPageSize), at: 0)
    let pageB = try file.readExactly(length: Int(Constants.headerPageSize), at: Constants.headerPageSize)
    let selected = try #require(WaxHeaderPage.selectValidPage(pageA: pageA, pageB: pageB))
    let writer = WALRingWriter(
        file: file,
        walOffset: selected.page.walOffset,
        walSize: selected.page.walSize,
        writePos: selected.page.walWritePos,
        checkpointPos: selected.page.walCheckpointPos,
        pendingBytes: 0,
        lastSequence: selected.page.walCommittedSeq
    )
    let payload = Data("torn".utf8)
    let checksum = SHA256Checksum.digest(payload)
    let offset = try file.size()
    try file.writeAll(Data(repeating: 0, count: payload.count), at: offset)
    let put = PutFrame(
        frameId: UInt64.max >> 1,
        timestampMs: 1,
        options: FrameMetaSubset(),
        payloadOffset: offset,
        payloadLength: UInt64(payload.count),
        canonicalEncoding: .plain,
        canonicalLength: UInt64(payload.count),
        canonicalChecksum: checksum,
        storedChecksum: checksum
    )
    _ = try writer.append(payload: try WALEntryCodec.encode(.putFrame(put)))
    try file.fsync()
}

@Test
func memoryStatsReportTornTailTruncationAfterCrash() async throws {
    try await TempFiles.withTempFile { url in
        let config = Memory.Config(enableVectorSearch: false, requireOnDeviceProviders: false)
        do {
            let memory = try await Memory(at: url, config: config)
            #expect(await memory.stats().walReplayTruncationCount == 0)
            try await memory.close()
        }

        try appendTornPendingPut(to: url)

        let recovered = try await Memory(at: url, config: config)
        let stats = await recovered.stats()
        #expect(stats.walReplayTruncationCount == 1)
        #expect(stats.pendingFrames == 0)
        try await recovered.close()
    }
}

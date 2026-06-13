import Foundation
import Testing
@testable import WaxCore

@Test
func scanPendingMutationsWithStateThrowsForChecksumValidUndecodableEntry() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }

        let walSize: UInt64 = 4096
        let corruptPayload = Data([0xFF])
        let recordData = try WALRecord.data(sequence: 1, flags: [], payload: corruptPayload).encode()
        try file.writeAll(recordData, at: 0)
        try file.writeAll(Data(repeating: 0, count: WALRecord.headerSize), at: UInt64(recordData.count))
        try file.fsync()

        let reader = WALRingReader(file: file, walOffset: 0, walSize: walSize)

        #expect(throws: WaxError.self) {
            _ = try reader.scanPendingMutationsWithState(from: 0, committedSeq: 0)
        }
    }
}

import Foundation

/// Package-facing WAL sizing helpers for higher-level maintenance code.
package enum WALSizing {
    /// Return the bytes consumed by a put-frame WAL record, including the
    /// fixed record header and the encoded frame metadata entry.
    package static func putFrameRecordBytes(_ put: PutFrame) throws -> UInt64 {
        let encodedEntry = try WALEntryCodec.encode(.putFrame(put))
        return UInt64(WALRecord.headerSize + encodedEntry.count)
    }
}

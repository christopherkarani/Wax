import Foundation

/// Read-only region backed by in-memory Data with a stable lifetime.
/// Useful for SQLite deserialize READONLY without extra copies.
///
/// @unchecked Sendable: NSData is immutable and the buffer address remains stable
/// for the lifetime of `storage`, which this class owns.
public final class InMemoryReadOnlyRegion: @unchecked Sendable {
    private let storage: NSData
    public let buffer: UnsafeRawBufferPointer

    public init(data: Data) throws {
        guard !data.isEmpty else {
            throw WaxError.io("read-only region requires non-empty data")
        }
        let nsData = data as NSData
        self.storage = nsData
        self.buffer = UnsafeRawBufferPointer(start: nsData.bytes, count: nsData.length)
    }

    public func close() {}
}

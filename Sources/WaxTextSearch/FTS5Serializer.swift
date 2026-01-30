import Foundation
import SQLite3
import WaxCore

enum FTS5Serializer {
    static func serialize(connection: OpaquePointer) throws -> Data {
        var size: Int64 = 0
        guard let raw = sqlite3_serialize(connection, "main", &size, 0) else {
            throw WaxError.io("sqlite3_serialize failed: \(sqliteMessage(connection))")
        }
        defer { sqlite3_free(raw) }
        guard size >= 0 else {
            throw WaxError.io("sqlite3_serialize returned negative size \(size)")
        }
        guard size <= Int64(Constants.maxBlobBytes) else {
            throw WaxError.capacityExceeded(limit: UInt64(Constants.maxBlobBytes), requested: UInt64(size))
        }
        guard size <= Int64(Int.max) else {
            throw WaxError.capacityExceeded(limit: UInt64(Int.max), requested: UInt64(size))
        }
        return Data(bytes: raw, count: Int(size))
    }

    static func deserialize(_ data: Data, into connection: OpaquePointer) throws {
        guard !data.isEmpty else {
            throw WaxError.io("sqlite3_deserialize requires non-empty data")
        }
        guard data.count <= Constants.maxBlobBytes else {
            throw WaxError.capacityExceeded(limit: UInt64(Constants.maxBlobBytes), requested: UInt64(data.count))
        }
        let size = data.count
        guard let buffer = sqlite3_malloc64(UInt64(size)) else {
            throw WaxError.io("sqlite3_malloc64 failed")
        }
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(buffer, base, size)
            }
        }
        let flags = UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_RESIZEABLE)
        let rc = sqlite3_deserialize(
            connection,
            "main",
            buffer.assumingMemoryBound(to: UInt8.self),
            Int64(size),
            Int64(size),
            flags
        )
        guard rc == SQLITE_OK else {
            sqlite3_free(buffer)
            throw WaxError.io("sqlite3_deserialize failed: \(sqliteMessage(connection))")
        }
    }

    static func deserializeReadOnly(_ region: MappedReadOnlyRegion, into connection: OpaquePointer) throws {
        guard region.buffer.count > 0 else {
            throw WaxError.io("sqlite3_deserialize requires non-empty data")
        }
        let size = region.buffer.count
        guard size <= Constants.maxBlobBytes else {
            throw WaxError.capacityExceeded(limit: UInt64(Constants.maxBlobBytes), requested: UInt64(size))
        }
        guard let base = region.buffer.baseAddress else {
            throw WaxError.io("mapped region base address missing")
        }
        let mutable = UnsafeMutablePointer<UInt8>(mutating: base.assumingMemoryBound(to: UInt8.self))
        let flags = UInt32(SQLITE_DESERIALIZE_READONLY)
        let rc = sqlite3_deserialize(
            connection,
            "main",
            mutable,
            Int64(size),
            Int64(size),
            flags
        )
        guard rc == SQLITE_OK else {
            throw WaxError.io("sqlite3_deserialize failed: \(sqliteMessage(connection))")
        }
    }

    static func deserializeReadOnly(_ region: InMemoryReadOnlyRegion, into connection: OpaquePointer) throws {
        guard region.buffer.count > 0 else {
            throw WaxError.io("sqlite3_deserialize requires non-empty data")
        }
        let size = region.buffer.count
        guard size <= Constants.maxBlobBytes else {
            throw WaxError.capacityExceeded(limit: UInt64(Constants.maxBlobBytes), requested: UInt64(size))
        }
        guard let base = region.buffer.baseAddress else {
            throw WaxError.io("read-only region base address missing")
        }
        let mutable = UnsafeMutablePointer<UInt8>(mutating: base.assumingMemoryBound(to: UInt8.self))
        let flags = UInt32(SQLITE_DESERIALIZE_READONLY)
        let rc = sqlite3_deserialize(
            connection,
            "main",
            mutable,
            Int64(size),
            Int64(size),
            flags
        )
        guard rc == SQLITE_OK else {
            throw WaxError.io("sqlite3_deserialize failed: \(sqliteMessage(connection))")
        }
    }

    private static func sqliteMessage(_ connection: OpaquePointer?) -> String {
        guard let connection else { return "no connection" }
        guard let message = sqlite3_errmsg(connection) else { return "unknown sqlite error" }
        return String(cString: message)
    }
}

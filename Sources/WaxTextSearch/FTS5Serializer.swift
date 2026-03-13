import Foundation
import WaxCore

#if canImport(SQLite3)
import SQLite3

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

    private static func sqliteMessage(_ connection: OpaquePointer?) -> String {
        guard let connection else { return "no connection" }
        guard let message = sqlite3_errmsg(connection) else { return "unknown sqlite error" }
        return String(cString: message)
    }
}

#else

// SQLite3 system module is not available on this platform (e.g. Linux without
// libsqlite3-dev). FTS5SearchEngine uses file-based GRDB persistence on Linux,
// so the in-memory serialize/deserialize path is not exercised. These stubs
// satisfy the type-checker so the target compiles cross-platform.
enum FTS5Serializer {
    static func serialize(connection: OpaquePointer) throws -> Data {
        throw WaxError.io("FTS5 in-memory serialization is not supported on this platform")
    }

    static func deserialize(_ data: Data, into connection: OpaquePointer) throws {
        throw WaxError.io("FTS5 in-memory deserialization is not supported on this platform")
    }
}

#endif

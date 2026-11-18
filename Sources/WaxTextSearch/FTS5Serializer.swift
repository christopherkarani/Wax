import Foundation
import WaxCore

#if canImport(Glibc)
import Glibc
#endif
#if canImport(SQLite3)
import SQLite3
#elseif canImport(GRDBSQLite)
import GRDBSQLite
#endif

#if canImport(SQLite3) || canImport(GRDBSQLite)

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

    /// The database image, without a copy when SQLite keeps it in one buffer (a database
    /// deserialized into memory), else a copy. A borrowed image stays valid only until the
    /// next write on `connection`.
    static func image(connection: OpaquePointer) throws -> (bytes: Data, borrowed: Bool) {
        var size: Int64 = 0
        guard let raw = sqlite3_serialize(connection, "main", &size, UInt32(SQLITE_SERIALIZE_NOCOPY)) else {
            return (try serialize(connection: connection), false)
        }
        guard size >= 0, size <= Int64(Constants.maxBlobBytes) else {
            throw WaxError.capacityExceeded(limit: UInt64(Constants.maxBlobBytes), requested: UInt64(max(0, size)))
        }
        return (Data(bytesNoCopy: raw, count: Int(size), deallocator: .none), true)
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
        // With SQLITE_DESERIALIZE_FREEONCLOSE, SQLite takes ownership of `buffer` even when
        // sqlite3_deserialize fails (it calls sqlite3_free before returning), so it must not
        // be freed here.
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

#else

// Neither Darwin SQLite3 nor GRDBSQLite is available. Persist-to-.wax then
// cannot snapshot the FTS5 database; callers get an explicit I/O error.
enum FTS5Serializer {
    static func serialize(connection: OpaquePointer) throws -> Data {
        throw WaxError.io("FTS5 in-memory serialization is not supported on this platform")
    }

    static func image(connection: OpaquePointer) throws -> (bytes: Data, borrowed: Bool) {
        throw WaxError.io("FTS5 in-memory serialization is not supported on this platform")
    }

    static func deserialize(_ data: Data, into connection: OpaquePointer) throws {
        throw WaxError.io("FTS5 in-memory deserialization is not supported on this platform")
    }
}

#endif

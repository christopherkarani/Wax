import Foundation

/// Deterministic binary decoder for Wax primitives.
package struct BinaryDecoder {
    package struct Limits: Sendable {
        package var maxStringBytes: Int = Constants.maxStringBytes
        package var maxBlobBytes: Int = Constants.maxBlobBytes
        package var maxArrayCount: Int = Constants.maxArrayCount

        package init() {}
    }

    private let data: Data
    private var cursor: Int = 0
    private let limits: Limits

    package init(data: Data, limits: Limits = .init()) throws {
        self.data = data
        self.limits = limits
    }

    // MARK: - Cursor helpers

    private mutating func read(count: Int, context: String) throws -> Data {
        guard count >= 0 else {
            throw WaxError.decodingError(reason: "invalid read size \(count) (\(context))")
        }
        guard cursor + count <= data.count else {
            throw WaxError.decodingError(reason: "truncated buffer while reading \(context)")
        }
        let range = cursor..<(cursor + count)
        cursor += count
        return data.subdata(in: range)
    }

    // MARK: - Primitives

    package mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
        let bytes = try read(count: 1, context: "UInt8")
        return bytes[0]
    }

    package mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
        let bytes = try read(count: 2, context: "UInt16")
        var raw: UInt16 = 0
        _ = withUnsafeMutableBytes(of: &raw) { dest in
            bytes.copyBytes(to: dest, count: 2)
        }
        return UInt16(littleEndian: raw)
    }

    package mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
        let bytes = try read(count: 4, context: "UInt32")
        var raw: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &raw) { dest in
            bytes.copyBytes(to: dest, count: 4)
        }
        return UInt32(littleEndian: raw)
    }

    package mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
        let bytes = try read(count: 8, context: "UInt64")
        var raw: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &raw) { dest in
            bytes.copyBytes(to: dest, count: 8)
        }
        return UInt64(littleEndian: raw)
    }

    package mutating func decode(_ type: Int64.Type) throws -> Int64 {
        let bytes = try read(count: 8, context: "Int64")
        var raw: Int64 = 0
        _ = withUnsafeMutableBytes(of: &raw) { dest in
            bytes.copyBytes(to: dest, count: 8)
        }
        return Int64(littleEndian: raw)
    }

    // MARK: - Variable bytes

    package mutating func decodeBytes(maxBytes: Int? = nil) throws -> Data {
        let length = Int(try decode(UInt32.self))
        let effectiveMax = maxBytes ?? limits.maxBlobBytes
        guard length <= effectiveMax else {
            throw WaxError.decodingError(reason: "length \(length) exceeds limit \(effectiveMax)")
        }
        return try read(count: length, context: "bytes[\(length)]")
    }

    // MARK: - Strings

    package mutating func decode(_ type: String.Type) throws -> String {
        let bytes = try decodeBytes(maxBytes: limits.maxStringBytes)
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw WaxError.decodingError(reason: "invalid UTF-8")
        }
        return value
    }

    // MARK: - Arrays

    package mutating func decodeArray<T>(_ type: T.Type = T.self) throws -> [T] {
        let count = Int(try decode(UInt32.self))
        guard count <= limits.maxArrayCount else {
            throw WaxError.decodingError(reason: "array count \(count) exceeds limit \(limits.maxArrayCount)")
        }

        var result: [T] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            result.append(try decode(type))
        }
        return result
    }

    // MARK: - Optionals

    package mutating func decodeOptional<T>(_ type: T.Type) throws -> T? {
        let tag = try decode(UInt8.self)
        switch tag {
        case 0:
            return nil
        case 1:
            return try decode(type)
        default:
            throw WaxError.decodingError(reason: "invalid optional tag \(tag)")
        }
    }

    // MARK: - Fixed bytes

    package mutating func decodeFixedBytes(count: Int) throws -> Data {
        return try read(count: count, context: "fixed bytes[\(count)]")
    }

    // MARK: - Generic decode support

    package mutating func decode<T>(_ type: T.Type) throws -> T {
        if type == UInt8.self { return try decode(UInt8.self) as! T }
        if type == UInt16.self { return try decode(UInt16.self) as! T }
        if type == UInt32.self { return try decode(UInt32.self) as! T }
        if type == UInt64.self { return try decode(UInt64.self) as! T }
        if type == Int64.self { return try decode(Int64.self) as! T }
        if type == String.self { return try decode(String.self) as! T }

        throw WaxError.decodingError(reason: "unsupported decode type: \(String(reflecting: type))")
    }

    // MARK: - Finalization

    package mutating func finalize() throws {
        if cursor != data.count {
            throw WaxError.decodingError(reason: "excess bytes (\(data.count - cursor))")
        }
    }
}

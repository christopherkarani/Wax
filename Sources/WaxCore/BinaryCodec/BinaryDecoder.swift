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
        // `cursor` counts from the first byte. A slice keeps its parent's indices,
        // so absolute positions add `startIndex` instead of copying the buffer.
        self.data = data
        self.limits = limits
    }

    // MARK: - Cursor helpers

    /// Bytes not yet consumed.
    package var remainingByteCount: Int { data.count - cursor }

    /// Whether `count` elements, each encoded in at least `minimumElementBytes`, can still
    /// fit in the unread bytes. Decoded counts are untrusted: check this before a count
    /// sizes any allocation (`reserveCapacity`, `Array(repeating:count:)`).
    package func canFit(count: Int, minimumElementBytes: Int) -> Bool {
        count >= 0 && count <= remainingByteCount / max(1, minimumElementBytes)
    }

    private func requireAvailable(_ count: Int, context: String) throws {
        guard count >= 0 else {
            throw WaxError.decodingError(reason: "invalid read size \(count) (\(context))")
        }
        guard count <= remainingByteCount else {
            throw WaxError.decodingError(reason: "truncated buffer while reading \(context)")
        }
    }

    private mutating func read(count: Int, context: String) throws -> Data {
        try requireAvailable(count, context: context)
        let start = data.startIndex + cursor
        cursor += count
        return data.subdata(in: start..<(start + count))
    }

    /// Reads a little-endian integer in place, without copying its bytes out first.
    private mutating func readInteger<T: FixedWidthInteger>(_ type: T.Type, context: String) throws -> T {
        let size = MemoryLayout<T>.size
        try requireAvailable(size, context: context)
        let offset = cursor
        let raw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        cursor += size
        return T(littleEndian: raw)
    }

    // MARK: - Primitives

    package mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
        try readInteger(UInt8.self, context: "UInt8")
    }

    package mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
        try readInteger(UInt16.self, context: "UInt16")
    }

    package mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
        try readInteger(UInt32.self, context: "UInt32")
    }

    package mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
        try readInteger(UInt64.self, context: "UInt64")
    }

    package mutating func decode(_ type: Int64.Type) throws -> Int64 {
        try readInteger(Int64.self, context: "Int64")
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

    package mutating func decodeArray(_ type: UInt8.Type) throws -> [UInt8] {
        try decodeArrayElements(minimumElementBytes: 1) { try $0.decode(UInt8.self) }
    }

    package mutating func decodeArray(_ type: UInt16.Type) throws -> [UInt16] {
        try decodeArrayElements(minimumElementBytes: 2) { try $0.decode(UInt16.self) }
    }

    package mutating func decodeArray(_ type: UInt32.Type) throws -> [UInt32] {
        try decodeArrayElements(minimumElementBytes: 4) { try $0.decode(UInt32.self) }
    }

    package mutating func decodeArray(_ type: UInt64.Type) throws -> [UInt64] {
        try decodeArrayElements(minimumElementBytes: 8) { try $0.decode(UInt64.self) }
    }

    package mutating func decodeArray(_ type: Int64.Type) throws -> [Int64] {
        try decodeArrayElements(minimumElementBytes: 8) { try $0.decode(Int64.self) }
    }

    package mutating func decodeArray(_ type: String.Type) throws -> [String] {
        // Every string carries a 4-byte length prefix.
        try decodeArrayElements(minimumElementBytes: 4) { try $0.decode(String.self) }
    }

    // MARK: - Optionals

    package mutating func decodeOptional(_ type: UInt8.Type) throws -> UInt8? {
        guard try decodeOptionalIsPresent() else { return nil }
        return try decode(UInt8.self)
    }

    package mutating func decodeOptional(_ type: UInt16.Type) throws -> UInt16? {
        guard try decodeOptionalIsPresent() else { return nil }
        return try decode(UInt16.self)
    }

    package mutating func decodeOptional(_ type: UInt32.Type) throws -> UInt32? {
        guard try decodeOptionalIsPresent() else { return nil }
        return try decode(UInt32.self)
    }

    package mutating func decodeOptional(_ type: UInt64.Type) throws -> UInt64? {
        guard try decodeOptionalIsPresent() else { return nil }
        return try decode(UInt64.self)
    }

    package mutating func decodeOptional(_ type: Int64.Type) throws -> Int64? {
        guard try decodeOptionalIsPresent() else { return nil }
        return try decode(Int64.self)
    }

    package mutating func decodeOptional(_ type: String.Type) throws -> String? {
        guard try decodeOptionalIsPresent() else { return nil }
        return try decode(String.self)
    }

    private mutating func decodeArrayElements<Element>(
        minimumElementBytes: Int,
        _ decodeElement: (inout BinaryDecoder) throws -> Element
    ) throws -> [Element] {
        let count = Int(try decode(UInt32.self))
        guard count <= limits.maxArrayCount else {
            throw WaxError.decodingError(reason: "array count \(count) exceeds limit \(limits.maxArrayCount)")
        }
        guard canFit(count: count, minimumElementBytes: minimumElementBytes) else {
            throw WaxError.decodingError(reason: "array count \(count) exceeds remaining bytes (\(remainingByteCount))")
        }

        var result: [Element] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            result.append(try decodeElement(&self))
        }
        return result
    }

    private mutating func decodeOptionalIsPresent() throws -> Bool {
        let tag = try decode(UInt8.self)
        switch tag {
        case 0:
            return false
        case 1:
            return true
        default:
            throw WaxError.decodingError(reason: "invalid optional tag \(tag)")
        }
    }

    // MARK: - Fixed bytes

    package mutating func decodeFixedBytes(count: Int) throws -> Data {
        return try read(count: count, context: "fixed bytes[\(count)]")
    }

    // MARK: - Finalization

    package mutating func finalize() throws {
        if cursor != data.count {
            throw WaxError.decodingError(reason: "excess bytes (\(data.count - cursor))")
        }
    }
}

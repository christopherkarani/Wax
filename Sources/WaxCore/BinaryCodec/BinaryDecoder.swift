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

    /// Consumes `count` bytes and returns their offset from the start of `data`.
    /// Decoding a TOC calls this tens of times per frame, so `context` is built only on error.
    private mutating func advance(by count: Int, context: @autoclosure () -> String) throws -> Int {
        guard count >= 0 else {
            throw WaxError.decodingError(reason: "invalid read size \(count) (\(context()))")
        }
        guard count <= data.count - cursor else {
            throw WaxError.decodingError(reason: "truncated buffer while reading \(context())")
        }
        let offset = cursor
        cursor += count
        return offset
    }

    private mutating func read(count: Int, context: @autoclosure () -> String) throws -> Data {
        let offset = try advance(by: count, context: context())
        let start = data.startIndex + offset
        return data.subdata(in: start..<(start + count))
    }

    /// Reads a little-endian integer in place, without copying it into a `Data` first.
    private mutating func decodeInteger<T: FixedWidthInteger>(_: T.Type, context: StaticString) throws -> T {
        let offset = try advance(by: MemoryLayout<T>.size, context: "\(context)")
        return T(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) })
    }

    // MARK: - Primitives

    package mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
        try decodeInteger(UInt8.self, context: "UInt8")
    }

    package mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
        try decodeInteger(UInt16.self, context: "UInt16")
    }

    package mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
        try decodeInteger(UInt32.self, context: "UInt32")
    }

    package mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
        try decodeInteger(UInt64.self, context: "UInt64")
    }

    package mutating func decode(_ type: Int64.Type) throws -> Int64 {
        try decodeInteger(Int64.self, context: "Int64")
    }

    // MARK: - Variable bytes

    package mutating func decodeBytes(maxBytes: Int? = nil) throws -> Data {
        let length = try decodeLength(maxBytes: maxBytes ?? limits.maxBlobBytes)
        return try read(count: length, context: "bytes[\(length)]")
    }

    private mutating func decodeLength(maxBytes: Int) throws -> Int {
        let length = Int(try decode(UInt32.self))
        guard length <= maxBytes else {
            throw WaxError.decodingError(reason: "length \(length) exceeds limit \(maxBytes)")
        }
        return length
    }

    // MARK: - Strings

    /// Validates the UTF-8 in place. Invalid UTF-8 throws; it is never repaired.
    package mutating func decode(_ type: String.Type) throws -> String {
        let length = try decodeLength(maxBytes: limits.maxStringBytes)
        let offset = try advance(by: length, context: "bytes[\(length)]")
        let value = data.withUnsafeBytes { raw in
            Self.validatedUTF8(UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + length)]))
        }
        guard let value else {
            throw WaxError.decodingError(reason: "invalid UTF-8")
        }
        return value
    }

    private static func validatedUTF8(_ raw: UnsafeRawBufferPointer) -> String? {
        let bytes = raw.assumingMemoryBound(to: UInt8.self)
        // Pure ASCII is valid UTF-8 and never repaired, so the specialized decode returns its
        // exact bytes. Most stored strings (metadata keys, ids, kinds) are ASCII, and this
        // skips the generic validating initializer, whose per-call metadata lookup was a third
        // of frame decoding when an open decodes the table of contents (100k frames).
        var combined: UInt8 = 0
        for byte in bytes {
            combined |= byte
        }
        if combined < 0x80 {
            return String(decoding: bytes, as: UTF8.self)
        }
        if #available(macOS 15, iOS 18, watchOS 11, tvOS 18, visionOS 2, *) {
            return String(validating: bytes, as: UTF8.self)
        }
        // `String(decoding:)` repairs invalid input, which always changes its bytes.
        let decoded = String(decoding: bytes, as: UTF8.self)
        return decoded.utf8.elementsEqual(bytes) ? decoded : nil
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

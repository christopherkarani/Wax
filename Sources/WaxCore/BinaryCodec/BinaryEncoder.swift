import Foundation

/// Deterministic binary encoder using little-endian byte order.
package struct BinaryEncoder {
    package struct Limits: Sendable {
        package var maxStringBytes: Int = Constants.maxStringBytes
        package var maxBlobBytes: Int = Constants.maxBlobBytes
        package var maxArrayCount: Int = Constants.maxArrayCount

        package init() {}
    }

    package private(set) var data = Data()
    private let limits: Limits

    package init(limits: Limits = .init()) {
        self.limits = limits
    }

    // MARK: - Primitives

    package mutating func encode(_ value: UInt8) {
        data.append(value)
    }

    package mutating func encode(_ value: UInt16) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    package mutating func encode(_ value: UInt32) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    package mutating func encode(_ value: UInt64) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    package mutating func encode(_ value: Int64) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    // MARK: - Optionals (tag byte + payload)

    package mutating func encode(_ value: UInt8?) {
        if let value {
            encode(UInt8(1))
            encode(value)
        } else {
            encode(UInt8(0))
        }
    }

    package mutating func encode(_ value: UInt16?) {
        if let value {
            encode(UInt8(1))
            encode(value)
        } else {
            encode(UInt8(0))
        }
    }

    package mutating func encode(_ value: UInt32?) {
        if let value {
            encode(UInt8(1))
            encode(value)
        } else {
            encode(UInt8(0))
        }
    }

    package mutating func encode(_ value: UInt64?) {
        if let value {
            encode(UInt8(1))
            encode(value)
        } else {
            encode(UInt8(0))
        }
    }

    package mutating func encode(_ value: Int64?) {
        if let value {
            encode(UInt8(1))
            encode(value)
        } else {
            encode(UInt8(0))
        }
    }

    // MARK: - Variable bytes (UInt32 length)

    package mutating func encodeBytes(_ value: Data) throws {
        guard value.count <= limits.maxBlobBytes else {
            throw WaxError.encodingError(reason: "byte length \(value.count) exceeds limit \(limits.maxBlobBytes)")
        }
        guard value.count <= Int(UInt32.max) else {
            throw WaxError.encodingError(reason: "byte array too large (\(value.count))")
        }
        encode(UInt32(value.count))
        data.append(value)
    }

    // MARK: - Strings (UInt32 byte length + UTF-8 bytes)

    package mutating func encode(_ value: String) throws {
        let utf8 = Data(value.utf8)
        guard utf8.count <= limits.maxStringBytes else {
            throw WaxError.encodingError(reason: "string byte length \(utf8.count) exceeds limit \(limits.maxStringBytes)")
        }
        try encodeBytes(utf8)
    }

    package mutating func encode(_ value: String?) throws {
        if let value {
            encode(UInt8(1))
            try encode(value)
        } else {
            encode(UInt8(0))
        }
    }

    // MARK: - Arrays (UInt32 count)

    package mutating func encode<T>(_ values: [T], encoder: (inout BinaryEncoder, T) throws -> Void) throws {
        guard values.count <= limits.maxArrayCount else {
            throw WaxError.encodingError(reason: "array count \(values.count) exceeds limit \(limits.maxArrayCount)")
        }
        guard values.count <= Int(UInt32.max) else {
            throw WaxError.encodingError(reason: "array too large (\(values.count))")
        }
        encode(UInt32(values.count))
        for value in values {
            try encoder(&self, value)
        }
    }

    package mutating func encode(_ values: [UInt8]) throws {
        guard values.count <= limits.maxArrayCount else {
            throw WaxError.encodingError(reason: "array count \(values.count) exceeds limit \(limits.maxArrayCount)")
        }
        guard values.count <= Int(UInt32.max) else {
            throw WaxError.encodingError(reason: "array too large (\(values.count))")
        }
        encode(UInt32(values.count))
        data.append(contentsOf: values)
    }

    package mutating func encode(_ values: [UInt16]) throws {
        guard values.count <= limits.maxArrayCount else {
            throw WaxError.encodingError(reason: "array count \(values.count) exceeds limit \(limits.maxArrayCount)")
        }
        guard values.count <= Int(UInt32.max) else {
            throw WaxError.encodingError(reason: "array too large (\(values.count))")
        }
        encode(UInt32(values.count))
        for value in values { encode(value) }
    }

    package mutating func encode(_ values: [UInt32]) throws {
        guard values.count <= limits.maxArrayCount else {
            throw WaxError.encodingError(reason: "array count \(values.count) exceeds limit \(limits.maxArrayCount)")
        }
        guard values.count <= Int(UInt32.max) else {
            throw WaxError.encodingError(reason: "array too large (\(values.count))")
        }
        encode(UInt32(values.count))
        for value in values { encode(value) }
    }

    package mutating func encode(_ values: [UInt64]) throws {
        guard values.count <= limits.maxArrayCount else {
            throw WaxError.encodingError(reason: "array count \(values.count) exceeds limit \(limits.maxArrayCount)")
        }
        guard values.count <= Int(UInt32.max) else {
            throw WaxError.encodingError(reason: "array too large (\(values.count))")
        }
        encode(UInt32(values.count))
        for value in values { encode(value) }
    }

    package mutating func encode(_ values: [Int64]) throws {
        guard values.count <= limits.maxArrayCount else {
            throw WaxError.encodingError(reason: "array count \(values.count) exceeds limit \(limits.maxArrayCount)")
        }
        guard values.count <= Int(UInt32.max) else {
            throw WaxError.encodingError(reason: "array too large (\(values.count))")
        }
        encode(UInt32(values.count))
        for value in values { encode(value) }
    }

    package mutating func encode(_ values: [String]) throws {
        try encode(values) { encoder, value in
            try encoder.encode(value)
        }
    }

    // MARK: - Optionals (tag byte + payload)

    package mutating func encode<T>(_ value: T?, encoder: (inout BinaryEncoder, T) throws -> Void) throws {
        if let value {
            encode(UInt8(1))
            try encoder(&self, value)
        } else {
            encode(UInt8(0))
        }
    }

    // MARK: - Fixed bytes (no length prefix)

    package mutating func encodeFixedBytes(_ value: Data) {
        data.append(value)
    }

    package mutating func appendRawBytes(_ value: Data) {
        data.append(value)
    }

    // MARK: - Padding

    package mutating func pad(to size: Int) {
        let remaining = size - data.count
        if remaining > 0 {
            data.append(Data(repeating: 0, count: remaining))
        }
    }
}

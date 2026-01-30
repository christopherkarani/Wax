import Foundation

/// Hashing utilities for structured memory deduplication and span identity.
public enum StructuredMemoryHasher {
    public static func hashFact(
        subject: EntityKey,
        predicate: PredicateKey,
        object: FactValue,
        qualifiersHash: Data?
    ) throws -> Data {
        var buffer = HashBuffer()
        buffer.appendTag(0xA1)
        buffer.appendString(subject.rawValue)
        buffer.appendTag(0xA2)
        buffer.appendString(predicate.rawValue)
        buffer.appendTag(0xA3)
        try buffer.appendFactValue(object)
        if let qualifiersHash {
            if qualifiersHash.count != 32 {
                throw WaxError.encodingError(reason: "qualifiers_hash must be 32 bytes")
            }
            buffer.appendTag(0xA4)
            buffer.appendBytes(qualifiersHash)
        }
        return SHA256Checksum.digest(buffer.data)
    }

    public static func hashSpanKey(
        factId: FactRowID,
        valid: StructuredTimeRange,
        systemFromMs: Int64
    ) -> Data {
        let validTo = valid.toMs ?? -1
        var buffer = HashBuffer()
        buffer.appendTag(0xB1)
        buffer.appendInt64(factId.rawValue)
        buffer.appendTag(0xB2)
        buffer.appendInt64(valid.fromMs)
        buffer.appendTag(0xB3)
        buffer.appendInt64(validTo)
        buffer.appendTag(0xB4)
        buffer.appendInt64(systemFromMs)
        return SHA256Checksum.digest(buffer.data)
    }
}

private struct HashBuffer {
    var data = Data()

    mutating func appendTag(_ tag: UInt8) {
        data.append(tag)
    }

    mutating func appendInt64(_ value: Int64) {
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 8))
    }

    mutating func appendUInt64(_ value: UInt64) {
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 8))
    }

    mutating func appendBytes(_ bytes: Data) {
        appendUInt64(UInt64(bytes.count))
        data.append(bytes)
    }

    mutating func appendString(_ value: String) {
        let normalized = StructuredMemoryCanonicalizer.normalizedString(value)
        appendBytes(Data(normalized.utf8))
    }

    mutating func appendBool(_ value: Bool) {
        data.append(value ? 0x01 : 0x00)
    }

    mutating func appendDouble(_ value: Double) throws {
        guard value.isFinite else {
            throw WaxError.encodingError(reason: "non-finite Double is not allowed")
        }
        let canonical = value == 0 ? 0.0 : value
        let bits = canonical.bitPattern
        appendUInt64(bits)
    }

    mutating func appendFactValue(_ value: FactValue) throws {
        switch value {
        case .string(let text):
            appendTag(0x01)
            appendString(text)
        case .int(let intValue):
            appendTag(0x02)
            appendInt64(intValue)
        case .double(let doubleValue):
            appendTag(0x03)
            try appendDouble(doubleValue)
        case .bool(let boolValue):
            appendTag(0x04)
            appendBool(boolValue)
        case .data(let dataValue):
            appendTag(0x05)
            appendBytes(dataValue)
        case .timeMs(let timeValue):
            appendTag(0x06)
            appendInt64(timeValue)
        case .entity(let entityKey):
            appendTag(0x07)
            appendString(entityKey.rawValue)
        }
    }
}

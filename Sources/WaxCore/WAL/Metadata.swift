import Foundation

package struct Metadata: Equatable, Sendable {
    package var entries: [String: String]

    package init(_ entries: [String: String] = [:]) {
        self.entries = entries
    }
}

extension Metadata: BinaryEncodable {
    package mutating func encode(to encoder: inout BinaryEncoder) throws {
        let keys = entries.keys.sorted()
        guard keys.count <= Constants.maxArrayCount else {
            throw WaxError.encodingError(reason: "metadata count \(keys.count) exceeds limit \(Constants.maxArrayCount)")
        }
        guard keys.count <= Int(UInt32.max) else {
            throw WaxError.encodingError(reason: "metadata count too large (\(keys.count))")
        }
        encoder.encode(UInt32(keys.count))
        for key in keys {
            guard let value = entries[key] else { continue }
            try encoder.encode(key)
            try encoder.encode(value)
        }
    }
}

extension Metadata: BinaryDecodable {
    package static func decode(from decoder: inout BinaryDecoder) throws -> Metadata {
        let count = Int(try decoder.decode(UInt32.self))
        guard count <= Constants.maxArrayCount else {
            throw WaxError.decodingError(reason: "metadata count \(count) exceeds limit \(Constants.maxArrayCount)")
        }

        var entries: [String: String] = [:]
        entries.reserveCapacity(count)

        for _ in 0..<count {
            let key = try decoder.decode(String.self)
            let value = try decoder.decode(String.self)
            if entries[key] != nil {
                throw WaxError.decodingError(reason: "duplicate metadata key: \(key)")
            }
            entries[key] = value
        }

        return Metadata(entries)
    }
}

import Foundation

package protocol BinaryEncodable {
    mutating func encode(to encoder: inout BinaryEncoder) throws
}

package protocol BinaryDecodable {
    static func decode(from decoder: inout BinaryDecoder) throws -> Self
}

package typealias BinaryCodable = BinaryEncodable & BinaryDecodable

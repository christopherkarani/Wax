import Crypto
import Foundation

/// Simple SHA-256 wrapper used by MV2S codecs.
public struct SHA256Checksum {
    private var hasher: SHA256 = .init()

    public init() {}

    public mutating func update(_ data: Data) {
        hasher.update(data: data)
    }

    public mutating func update(_ bytes: UnsafeRawBufferPointer) {
        hasher.update(bufferPointer: bytes)
    }

    public mutating func finalize() -> Data {
        Data(hasher.finalize())
    }

    public static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

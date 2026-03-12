import Crypto
import Foundation

/// Simple SHA-256 wrapper used by Wax codecs.
package struct SHA256Checksum {
    private var hasher: SHA256 = .init()

    package init() {}

    package mutating func update(_ data: Data) {
        hasher.update(data: data)
    }

    package mutating func update(_ bytes: UnsafeRawBufferPointer) {
        hasher.update(bufferPointer: bytes)
    }

    package mutating func finalize() -> Data {
        Data(hasher.finalize())
    }

    package static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

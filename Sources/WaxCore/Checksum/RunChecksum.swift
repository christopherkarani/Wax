import Dispatch
import Foundation

/// The checksum of a vector or lex run.
///
/// A run's manifest records a checksum chunk size. Without one (runs written before format
/// 3.1) the checksum is the SHA-256 of the whole run. With one it is a tree checksum: the run
/// is split into chunks of that many bytes, the last one shorter, and the checksum is the
/// SHA-256 of the chunks' SHA-256 digests, concatenated in order. An empty run is one empty
/// chunk. The chunks hash on all cores, where one SHA-256 runs at about 2.75 GB/s.
package enum RunChecksum {
    /// Chunk size of the tree checksum new runs are written with.
    package static let treeChunkBytes: UInt32 = 4 << 20

    /// Smallest chunk size a manifest may record, which bounds the digests a run needs.
    package static let minimumChunkBytes: UInt32 = 64 << 10

    private static let digestBytes = 32

    /// The checksum of `data`: its SHA-256 when `chunkBytes` is `nil`, else its tree checksum.
    package static func digest(_ data: Data, chunkBytes: UInt32?) -> Data {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data in
            digest(raw, chunkBytes: chunkBytes)
        }
    }

    /// The checksum of `bytes`: their SHA-256 when `chunkBytes` is `nil`, else their tree
    /// checksum, its chunks hashed in parallel.
    package static func digest(_ bytes: UnsafeRawBufferPointer, chunkBytes: UInt32?) -> Data {
        guard let chunkBytes else {
            var hasher = SHA256Checksum()
            hasher.update(bytes)
            return hasher.finalize()
        }
        let chunk = Int(chunkBytes)
        let count = chunkCount(byteCount: bytes.count, chunkBytes: chunk)
        let digests = UnsafeMutableRawBufferPointer.allocate(byteCount: count * digestBytes, alignment: 1)
        defer { digests.deallocate() }
        if count == 1 {
            writeChunkDigest(0, of: bytes, chunkBytes: chunk, to: digests)
        } else {
            // The calling thread runs iterations too, so this completes even with no worker free.
            let work = ChunkDigestWork(bytes: bytes, digests: digests, chunkBytes: chunk)
            DispatchQueue.concurrentPerform(iterations: count) { (index: Int) in
                work.run(index)
            }
        }
        return root(of: UnsafeRawBufferPointer(digests))
    }

    /// Chunks of `chunkBytes` in a run of `byteCount` bytes: at least one.
    static func chunkCount(byteCount: Int, chunkBytes: Int) -> Int {
        max(1, (byteCount + chunkBytes - 1) / chunkBytes)
    }

    /// Writes the SHA-256 of chunk `index` of `bytes` to its 32 bytes of `digests`.
    static func writeChunkDigest(
        _ index: Int,
        of bytes: UnsafeRawBufferPointer,
        chunkBytes: Int,
        to digests: UnsafeMutableRawBufferPointer
    ) {
        let start = index * chunkBytes
        let end = min(start + chunkBytes, bytes.count)
        var hasher = SHA256Checksum()
        hasher.update(UnsafeRawBufferPointer(rebasing: bytes[start..<end]))
        let digest = hasher.finalize()
        digest.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            UnsafeMutableRawBufferPointer(rebasing: digests[(index * digestBytes)..<((index + 1) * digestBytes)])
                .copyMemory(from: source)
        }
    }

    /// The tree checksum of the concatenated chunk `digests`.
    static func root(of digests: UnsafeRawBufferPointer) -> Data {
        var hasher = SHA256Checksum()
        hasher.update(digests)
        return hasher.finalize()
    }

    /// A run's checksum computed from its bytes in pieces of any size, for reads that stream.
    package struct Hasher {
        private let chunkBytes: Int?
        private var whole = SHA256Checksum()
        private var chunk = SHA256Checksum()
        private var bytesInChunk = 0
        private var chunksDone = 0

        package init(chunkBytes: UInt32?) {
            self.chunkBytes = chunkBytes.map(Int.init)
        }

        package mutating func update(_ bytes: UnsafeRawBufferPointer) {
            guard let chunkBytes else {
                whole.update(bytes)
                return
            }
            var start = 0
            while start < bytes.count {
                let take = min(chunkBytes - bytesInChunk, bytes.count - start)
                chunk.update(UnsafeRawBufferPointer(rebasing: bytes[start..<(start + take)]))
                bytesInChunk += take
                start += take
                if bytesInChunk == chunkBytes {
                    finishChunk()
                }
            }
        }

        package mutating func finalize() -> Data {
            if chunkBytes != nil, bytesInChunk > 0 || chunksDone == 0 {
                finishChunk()
            }
            return whole.finalize()
        }

        private mutating func finishChunk() {
            whole.update(chunk.finalize())
            chunk = SHA256Checksum()
            bytesInChunk = 0
            chunksDone += 1
        }
    }

    // MARK: - Manifest field

    /// Encodes a run's checksum chunk size as an optional: a tag, then the size when present.
    static func encode(chunkBytes: UInt32?, to encoder: inout BinaryEncoder) throws {
        guard let chunkBytes else {
            encoder.encode(UInt8(0))
            return
        }
        guard chunkBytes >= minimumChunkBytes else {
            throw WaxError.encodingError(reason: "run checksum chunk size \(chunkBytes) below \(minimumChunkBytes)")
        }
        encoder.encode(UInt8(1))
        encoder.encode(chunkBytes)
    }

    static func decodeChunkBytes(from decoder: inout BinaryDecoder) throws -> UInt32? {
        let tag = try decoder.decode(UInt8.self)
        switch tag {
        case 0:
            return nil
        case 1:
            let chunkBytes = try decoder.decode(UInt32.self)
            guard chunkBytes >= minimumChunkBytes else {
                throw WaxError.decodingError(reason: "run checksum chunk size \(chunkBytes) below \(minimumChunkBytes)")
            }
            return chunkBytes
        default:
            throw WaxError.decodingError(reason: "invalid run checksum chunk size tag \(tag)")
        }
    }
}

/// One tree checksum's chunk hashing, shared by the `concurrentPerform` workers.
///
/// `@unchecked Sendable`: `bytes` is only read, iteration `i` writes only its own 32 bytes of
/// `digests`, and both buffers outlive `concurrentPerform`, which returns before they are freed.
private struct ChunkDigestWork: @unchecked Sendable {
    let bytes: UnsafeRawBufferPointer
    let digests: UnsafeMutableRawBufferPointer
    let chunkBytes: Int

    func run(_ index: Int) {
        RunChecksum.writeChunkDigest(index, of: bytes, chunkBytes: chunkBytes, to: digests)
    }
}

import Foundation

/// The header of a lex delta run: the pages of the lex image one commit changed.
///
/// A lex index is a base image followed by delta runs, applied oldest first. The image is the
/// text index's serialized SQLite database, cut into pages of `pageSize` bytes; its last page
/// is shorter when the image length is not a multiple of the page size. The base is the raw
/// image, the layout of a v2 store's whole lex blob, so migration adopts that blob in place.
///
/// A delta run, little-endian: `"WLXD"`, version `u16`, reserved `u16`, page size `u32`, page
/// count `u32`, image length `u64` (the image's length after the run); then the page indices
/// (`u32`, ascending) and the pages' bytes in the same order. A run that grows the image holds
/// every page past the old end, and the old last page when it was short.
package struct LexDeltaRunHeader: Equatable, Sendable {
    package var pageSize: UInt32
    package var pageCount: UInt32
    package var imageLength: UInt64
}

enum LexRunCodec {
    static let magic = Data([0x57, 0x4C, 0x58, 0x44])
    static let version: UInt16 = 1
    static let headerSize = 24
    /// Page sizes SQLite allows.
    static let pageSizes: ClosedRange<Int> = 512...65_536

    static func pageCount(imageLength: Int, pageSize: Int) -> Int {
        (imageLength + pageSize - 1) / pageSize
    }

    /// Bytes of page `index` of an image of `imageLength` bytes.
    static func pageLength(_ index: Int, pageSize: Int, imageLength: Int) -> Int {
        min(pageSize, imageLength - index * pageSize)
    }

    /// The page size of `image`: its SQLite header's when it has one, else `fallback`.
    static func pageSize(of image: UnsafeRawBufferPointer, fallback: Int) -> Int {
        guard image.count >= 100, sqliteHeader.elementsEqual(image.prefix(16)) else { return fallback }
        // Big-endian at offset 16; 1 means 65536.
        let raw = Int(image[16]) << 8 | Int(image[17])
        let size = raw == 1 ? 65_536 : raw
        guard pageSizes.contains(size), size & (size - 1) == 0 else { return fallback }
        return size
    }

    private static let sqliteHeader = Array("SQLite format 3\u{0}".utf8)

    static func encodedLength(pages indices: [Int], pageSize: Int, imageLength: Int) -> Int {
        var length = headerSize + indices.count * MemoryLayout<UInt32>.stride
        for index in indices {
            length += pageLength(index, pageSize: pageSize, imageLength: imageLength)
        }
        return length
    }

    /// A delta run holding pages `indices` (ascending) of `image`.
    static func encode(pages indices: [Int], of image: UnsafeRawBufferPointer, pageSize: Int) throws -> Data {
        guard pageSizes.contains(pageSize) else {
            throw WaxError.encodingError(reason: "lex page size \(pageSize) out of range")
        }
        guard indices.count <= Int(UInt32.max), image.count <= Constants.maxBlobBytes else {
            throw WaxError.capacityExceeded(limit: UInt64(Constants.maxBlobBytes), requested: UInt64(image.count))
        }
        let imageLength = image.count
        let pages = pageCount(imageLength: imageLength, pageSize: pageSize)
        for (position, index) in indices.enumerated() {
            guard index >= 0, index < pages, position == 0 || indices[position - 1] < index else {
                throw WaxError.encodingError(reason: "lex run pages must be ascending pages of the image")
            }
        }
        var data = Data(count: encodedLength(pages: indices, pageSize: pageSize, imageLength: imageLength))
        data.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            let base = output.baseAddress!
            magic.withUnsafeBytes { base.copyMemory(from: $0.baseAddress!, byteCount: 4) }
            output.storeBytes(of: version.littleEndian, toByteOffset: 4, as: UInt16.self)
            output.storeBytes(of: UInt16(0), toByteOffset: 6, as: UInt16.self)
            output.storeBytes(of: UInt32(pageSize).littleEndian, toByteOffset: 8, as: UInt32.self)
            output.storeBytes(of: UInt32(indices.count).littleEndian, toByteOffset: 12, as: UInt32.self)
            output.storeBytes(of: UInt64(imageLength).littleEndian, toByteOffset: 16, as: UInt64.self)
            var offset = headerSize
            for index in indices {
                output.storeBytes(of: UInt32(index).littleEndian, toByteOffset: offset, as: UInt32.self)
                offset += MemoryLayout<UInt32>.stride
            }
            for index in indices {
                let length = pageLength(index, pageSize: pageSize, imageLength: imageLength)
                (base + offset).copyMemory(from: image.baseAddress! + index * pageSize, byteCount: length)
                offset += length
            }
        }
        return data
    }

    static func decodeHeader(_ data: Data) throws -> LexDeltaRunHeader {
        guard data.count >= headerSize else {
            throw WaxError.invalidToc(reason: "lex run too small: \(data.count) bytes")
        }
        guard data.prefix(4) == magic else {
            throw WaxError.invalidToc(reason: "lex run magic mismatch")
        }
        let header = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (UInt16, LexDeltaRunHeader) in
            (
                UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt16.self)),
                LexDeltaRunHeader(
                    pageSize: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self)),
                    pageCount: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self)),
                    imageLength: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 16, as: UInt64.self))
                )
            )
        }
        guard header.0 == version else {
            throw WaxError.invalidToc(reason: "unsupported lex run version \(header.0)")
        }
        guard pageSizes.contains(Int(header.1.pageSize)) else {
            throw WaxError.invalidToc(reason: "lex run page size \(header.1.pageSize) out of range")
        }
        guard header.1.imageLength > 0, header.1.imageLength <= UInt64(Constants.maxBlobBytes) else {
            throw WaxError.invalidToc(reason: "lex run image length \(header.1.imageLength) out of range")
        }
        return header.1
    }

    /// Applies the delta run `run` to `image`, which takes the run's image length.
    static func apply(_ run: Data, to image: inout Data, pageSize expectedPageSize: Int) throws {
        let header = try decodeHeader(run)
        let pageSize = Int(header.pageSize)
        guard pageSize == expectedPageSize else {
            throw WaxError.invalidToc(reason: "lex run page size \(pageSize) differs from its manifest's \(expectedPageSize)")
        }
        let newLength = Int(header.imageLength)
        let count = Int(header.pageCount)
        let pages = pageCount(imageLength: newLength, pageSize: pageSize)
        let indicesEnd = headerSize + count * MemoryLayout<UInt32>.stride
        guard count <= pages, run.count >= indicesEnd else {
            throw WaxError.invalidToc(reason: "lex run shorter than its page list")
        }
        let indices = run.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Int] in
            (0..<count).map { position in
                Int(UInt32(littleEndian: raw.loadUnaligned(
                    fromByteOffset: headerSize + position * MemoryLayout<UInt32>.stride,
                    as: UInt32.self
                )))
            }
        }
        var expectedLength = indicesEnd
        for (position, index) in indices.enumerated() {
            guard index < pages, position == 0 || indices[position - 1] < index else {
                throw WaxError.invalidToc(reason: "lex run pages are not ascending pages of its image")
            }
            expectedLength += pageLength(index, pageSize: pageSize, imageLength: newLength)
        }
        guard run.count == expectedLength else {
            throw WaxError.invalidToc(reason: "lex run length differs from its pages")
        }
        // Bytes past the old end exist only in this run: it must hold every page they touch.
        let oldLength = image.count
        if newLength > oldLength {
            let firstNew = oldLength / pageSize
            let needed = pages - firstNew
            guard needed <= count, indices[count - needed] == firstNew else {
                throw WaxError.invalidToc(reason: "lex run grows its image without the new pages")
            }
        }

        image.count = newLength
        run.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            image.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                var offset = indicesEnd
                for index in indices {
                    let length = pageLength(index, pageSize: pageSize, imageLength: newLength)
                    (target.baseAddress! + index * pageSize).copyMemory(
                        from: source.baseAddress! + offset,
                        byteCount: length
                    )
                    offset += length
                }
            }
        }
    }
}

/// Page fingerprints: XXH64 of each page, with a seed drawn per store handle.
///
/// They live only in memory and only decide which pages a commit writes, so a collision would
/// leave a changed page out of a run. With 64 bits that is a 2^-64 chance per changed page, and
/// the seed, unknown outside the process, keeps page contents from being crafted to collide.
enum LexPageFingerprint {
    static func fingerprints(of image: UnsafeRawBufferPointer, pageSize: Int, seed: UInt64) -> [UInt64] {
        let count = LexRunCodec.pageCount(imageLength: image.count, pageSize: pageSize)
        var hashes = [UInt64](repeating: 0, count: count)
        hashes.withUnsafeMutableBufferPointer { (output: inout UnsafeMutableBufferPointer<UInt64>) in
            for index in 0..<count {
                let start = index * pageSize
                let end = min(start + pageSize, image.count)
                output[index] = xxh64(UnsafeRawBufferPointer(rebasing: image[start..<end]), seed: seed)
            }
        }
        return hashes
    }

    private static let prime1: UInt64 = 0x9E37_79B1_85EB_CA87
    private static let prime2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
    private static let prime3: UInt64 = 0x1656_67B1_9E37_79F9
    private static let prime4: UInt64 = 0x85EB_CA77_C2B2_AE63
    private static let prime5: UInt64 = 0x27D4_EB2F_1656_67C5

    @inline(__always)
    private static func rotl(_ value: UInt64, _ count: UInt64) -> UInt64 {
        (value << count) | (value >> (64 - count))
    }

    @inline(__always)
    private static func round(_ accumulator: UInt64, _ input: UInt64) -> UInt64 {
        rotl(accumulator &+ input &* prime2, 31) &* prime1
    }

    @inline(__always)
    private static func merge(_ accumulator: UInt64, _ lane: UInt64) -> UInt64 {
        (accumulator ^ round(0, lane)) &* prime1 &+ prime4
    }

    /// XXH64 of `bytes`.
    static func xxh64(_ bytes: UnsafeRawBufferPointer, seed: UInt64) -> UInt64 {
        let length = bytes.count
        @inline(__always) func word(_ offset: Int) -> UInt64 {
            UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        }
        var offset = 0
        var hash: UInt64
        if length >= 32 {
            var lane1 = seed &+ prime1 &+ prime2
            var lane2 = seed &+ prime2
            var lane3 = seed
            var lane4 = seed &- prime1
            while offset + 32 <= length {
                lane1 = round(lane1, word(offset))
                lane2 = round(lane2, word(offset + 8))
                lane3 = round(lane3, word(offset + 16))
                lane4 = round(lane4, word(offset + 24))
                offset += 32
            }
            hash = rotl(lane1, 1) &+ rotl(lane2, 7) &+ rotl(lane3, 12) &+ rotl(lane4, 18)
            hash = merge(hash, lane1)
            hash = merge(hash, lane2)
            hash = merge(hash, lane3)
            hash = merge(hash, lane4)
        } else {
            hash = seed &+ prime5
        }
        hash = hash &+ UInt64(length)
        while offset + 8 <= length {
            hash = rotl(hash ^ round(0, word(offset)), 27) &* prime1 &+ prime4
            offset += 8
        }
        if offset + 4 <= length {
            let half = UInt64(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            hash = rotl(hash ^ (half &* prime1), 23) &* prime2 &+ prime3
            offset += 4
        }
        while offset < length {
            hash = rotl(hash ^ (UInt64(bytes[offset]) &* prime5), 11) &* prime1
            offset += 1
        }
        hash ^= hash >> 33
        hash = hash &* prime2
        hash ^= hash >> 29
        hash = hash &* prime3
        hash ^= hash >> 32
        return hash
    }
}

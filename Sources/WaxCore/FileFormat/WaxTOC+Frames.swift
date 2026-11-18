import Foundation

extension WaxTOC {
    /// Frame counts below this decode on the calling thread.
    static let parallelFrameDecodeThreshold = 8_192

    /// Where a frame record starts: its index and its offset from the decoder's first byte.
    package struct FrameRecordStart: Equatable, Sendable {
        package var frame: Int
        package var offset: Int

        package init(frame: Int, offset: Int) {
            self.frame = frame
            self.offset = offset
        }
    }

    /// Decodes the TOC's `count` frame records, which start at `decoder`'s position, and
    /// leaves `decoder` just past them.
    ///
    /// Each record decodes its strings, checksums and metadata one after another, about
    /// 0.8 µs a frame: most of a 100k-frame store's open. Large TOCs decode in chunks on all
    /// cores instead, several per core so cores that finish early take the remaining chunks.
    static func decodeFrames(count: Int, from decoder: inout BinaryDecoder) throws -> [FrameMeta] {
        let chunkCount = count >= parallelFrameDecodeThreshold
            ? min(4 * ProcessInfo.processInfo.activeProcessorCount, count / 1_024)
            : 1
        return try decodeFrames(count: count, chunkCount: chunkCount, from: &decoder)
    }

    /// Decodes `count` frame records in up to `chunkCount` chunks at once.
    ///
    /// ``speculativeChunkStarts(count:chunkCount:in:)`` guesses where each chunk starts
    /// without reading the records before it. The guesses are checked as the chunks decode:
    /// the first chunk starts at the first record, and each chunk must decode all its frames
    /// and end exactly where the next chunk starts, so every chunk starts where a sequential
    /// decode reaches its first frame. A wrong guess decodes again from starts found by
    /// skipping the records. Anything else (a chunk that fails, a boundary that disagrees)
    /// decodes again on one thread, so the frames and any error are exactly those of a
    /// sequential decode.
    package static func decodeFrames(
        count: Int,
        chunkCount: Int,
        from decoder: inout BinaryDecoder
    ) throws -> [FrameMeta] {
        if chunkCount > 1, count > 1,
           let frames = decodeFramesInParallel(count: count, chunkCount: min(chunkCount, count), from: &decoder) {
            return frames
        }
        var frames: [FrameMeta] = []
        frames.reserveCapacity(count)
        for _ in 0..<count {
            frames.append(try FrameMeta.decode(from: &decoder))
        }
        return frames
    }

    /// Records a candidate start must be followed by, with consecutive ids, to count as a
    /// frame record start.
    static let speculativeStartConfirmations = 3

    /// Guesses where `chunkCount` chunks of the `count` frame records at `decoder`'s position
    /// start, without reading the records before each.
    ///
    /// Records vary in length, so finding a record's start used to take a pass over every
    /// record before it (15 ms of a 100k-frame open). Instead, chunk `k` searches forward
    /// from `k / chunkCount` of the remaining bytes for an offset that parses as a record
    /// whose id is below `count`, followed by records with the next ids. Ids are dense, so
    /// a record start almost always passes and other bytes almost never do; a guess that
    /// is wrong anyway fails the decode's boundary check. A chunk whose search finds nothing
    /// before the next chunk's search area, or a guess out of order, is dropped: the chunk
    /// before it grows. The first start is always the first record.
    package static func speculativeChunkStarts(
        count: Int,
        chunkCount: Int,
        in decoder: BinaryDecoder
    ) -> [FrameRecordStart] {
        let first = FrameRecordStart(frame: 0, offset: decoder.position)
        guard chunkCount > 1, count > 1 else { return [first] }
        let span = decoder.remainingByteCount
        let found = UnsafeMutableBufferPointer<FrameRecordStart?>.allocate(capacity: chunkCount - 1)
        found.initialize(repeating: nil)
        defer { found.deallocate() }
        decoder.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let work = ChunkStartSearch(
                decoder: decoder,
                bytes: raw,
                count: count,
                areaStarts: (0...chunkCount).map { (area: Int) -> Int in first.offset + span / chunkCount * area },
                found: found.baseAddress!
            )
            DispatchQueue.concurrentPerform(iterations: chunkCount - 1) { (index: Int) in
                work.run(chunk: index + 1)
            }
        }
        var starts = [first]
        for case let start? in found {
            guard let last = starts.last, start.frame > last.frame, start.offset > last.offset else { continue }
            starts.append(start)
        }
        return starts
    }

    /// Where `chunkCount` chunks of the `count` frame records at `decoder`'s position start,
    /// found by skipping every record before each, or `nil` when a record does not parse.
    static func skippedChunkStarts(count: Int, chunkCount: Int, in decoder: BinaryDecoder) -> [FrameRecordStart]? {
        let framesPerChunk = (count + chunkCount - 1) / chunkCount
        var probe = decoder
        var starts: [FrameRecordStart] = []
        starts.reserveCapacity(chunkCount)
        do {
            for index in 0..<count {
                if index % framesPerChunk == 0 {
                    starts.append(FrameRecordStart(frame: index, offset: probe.position))
                }
                try FrameMeta.skip(in: &probe)
            }
        } catch {
            return nil
        }
        return starts
    }

    /// The parallel decode, or `nil` (leaving `decoder` where it was) when any part of it fails.
    ///
    /// Chunks start where ``speculativeChunkStarts(count:chunkCount:in:)`` guesses, or, when
    /// a guess is wrong, where ``skippedChunkStarts(count:chunkCount:in:)`` finds them.
    private static func decodeFramesInParallel(
        count: Int,
        chunkCount: Int,
        from decoder: inout BinaryDecoder
    ) -> [FrameMeta]? {
        let guessed = speculativeChunkStarts(count: count, chunkCount: chunkCount, in: decoder)
        if guessed.count > 1, let frames = decodeChunks(count: count, startingAt: guessed, from: &decoder) {
            return frames
        }
        guard let skipped = skippedChunkStarts(count: count, chunkCount: chunkCount, in: decoder),
              skipped.count > 1
        else { return nil }
        return decodeChunks(count: count, startingAt: skipped, from: &decoder)
    }

    /// Decodes the chunks that start at `starts` (the first at `decoder`'s position) on all
    /// cores, or returns `nil` (leaving `decoder` where it was) when a chunk fails or does
    /// not end where the next one starts.
    private static func decodeChunks(
        count: Int,
        startingAt starts: [FrameRecordStart],
        from decoder: inout BinaryDecoder
    ) -> [FrameMeta]? {
        var end: Int?
        let frames = decoder.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [FrameMeta] in
            [FrameMeta](unsafeUninitializedCapacity: count) { buffer, initializedCount in
                let chunks = starts.count
                let initialized = UnsafeMutableBufferPointer<Int>.allocate(capacity: chunks)
                initialized.initialize(repeating: 0)
                defer { initialized.deallocate() }
                let ends = UnsafeMutableBufferPointer<Int>.allocate(capacity: chunks)
                ends.initialize(repeating: -1)
                defer { ends.deallocate() }
                let work = FrameChunkDecode(
                    decoder: decoder,
                    bytes: raw,
                    starts: starts,
                    frameCount: count,
                    frames: buffer.baseAddress!,
                    initialized: initialized.baseAddress!,
                    ends: ends.baseAddress!
                )
                DispatchQueue.concurrentPerform(iterations: chunks) { (chunk: Int) in
                    work.run(chunk: chunk)
                }

                let joined = (0..<chunks).allSatisfy { (chunk: Int) -> Bool in
                    chunk == chunks - 1 ? ends[chunk] >= 0 : ends[chunk] == starts[chunk + 1].offset
                }
                if joined {
                    end = ends[chunks - 1]
                    initializedCount = count
                    return
                }
                for chunk in 0..<chunks {
                    (buffer.baseAddress! + starts[chunk].frame).deinitialize(count: initialized[chunk])
                }
                initializedCount = 0
            }
        }
        guard let end, (try? decoder.seek(to: end)) != nil else { return nil }
        return frames
    }
}

/// One TOC decode's search for chunk starts, shared by the `concurrentPerform` workers.
///
/// `@unchecked Sendable`: `bytes` points into the decoder's buffer and `found` to a buffer
/// of one slot per searched chunk, both kept alive by the caller for the whole join; each
/// worker writes only its own slot. The decoder is only read from.
private final class ChunkStartSearch: @unchecked Sendable {
    let decoder: BinaryDecoder
    let bytes: UnsafeRawBufferPointer
    let count: Int
    let areaStarts: [Int]
    let found: UnsafeMutablePointer<WaxTOC.FrameRecordStart?>

    init(
        decoder: BinaryDecoder,
        bytes: UnsafeRawBufferPointer,
        count: Int,
        areaStarts: [Int],
        found: UnsafeMutablePointer<WaxTOC.FrameRecordStart?>
    ) {
        self.decoder = decoder
        self.bytes = bytes
        self.count = count
        self.areaStarts = areaStarts
        self.found = found
    }

    /// Searches chunk `chunk`'s area, from `areaStarts[chunk]` to where the next chunk's
    /// begins, for the first offset where a confirmed record starts.
    func run(chunk: Int) {
        let areaStart = areaStarts[chunk]
        let areaEnd = min(areaStarts[chunk + 1], bytes.count - 8)
        guard areaStart < areaEnd else { return }
        let probe = decoder.borrowing(areaStart..<bytes.count, of: bytes)
        for offset in areaStart..<areaEnd {
            guard let id = id(at: offset), confirms(offset, id: id, in: probe, startingAt: areaStart) else { continue }
            found[chunk - 1] = WaxTOC.FrameRecordStart(frame: id, offset: offset)
            return
        }
    }

    /// The little-endian 8 bytes at `offset` when they could be a frame id, below `count`.
    private func id(at offset: Int) -> Int? {
        guard offset + 8 <= bytes.count else { return nil }
        let value = UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        return value < UInt64(count) ? Int(value) : nil
    }

    /// Whether records with ids `id`, `id + 1`, ... (up to the confirmation count, fewer
    /// when the last frame comes first) parse back to back from `offset`. `probe` reads the
    /// bytes from `probeStart` on.
    private func confirms(_ offset: Int, id: Int, in probe: BinaryDecoder, startingAt probeStart: Int) -> Bool {
        var probe = probe
        guard (try? probe.seek(to: offset - probeStart)) != nil else { return false }
        for next in id..<min(count, id + WaxTOC.speculativeStartConfirmations) {
            guard self.id(at: probeStart + probe.position) == next,
                  (try? FrameMeta.skip(in: &probe)) != nil
            else { return false }
        }
        return true
    }
}

/// One TOC decode's chunk work, shared by the `concurrentPerform` workers.
///
/// `@unchecked Sendable`: the pointers reference buffers the caller keeps alive for the
/// whole join, and each worker writes only its own chunk's frames and its own `initialized`
/// and `ends` slots. The decoder is only read from.
private final class FrameChunkDecode: @unchecked Sendable {
    let decoder: BinaryDecoder
    let bytes: UnsafeRawBufferPointer
    let starts: [WaxTOC.FrameRecordStart]
    let frameCount: Int
    let frames: UnsafeMutablePointer<FrameMeta>
    let initialized: UnsafeMutablePointer<Int>
    let ends: UnsafeMutablePointer<Int>

    init(
        decoder: BinaryDecoder,
        bytes: UnsafeRawBufferPointer,
        starts: [WaxTOC.FrameRecordStart],
        frameCount: Int,
        frames: UnsafeMutablePointer<FrameMeta>,
        initialized: UnsafeMutablePointer<Int>,
        ends: UnsafeMutablePointer<Int>
    ) {
        self.decoder = decoder
        self.bytes = bytes
        self.starts = starts
        self.frameCount = frameCount
        self.frames = frames
        self.initialized = initialized
        self.ends = ends
    }

    /// Decodes the chunk's frames in place, counting each in `initialized[chunk]`, and sets
    /// `ends[chunk]` to the offset after its last frame when all of them decoded.
    ///
    /// Each chunk reads the buffer through a decoder of its own that borrows the bytes:
    /// chunks reading one shared `Data` contend on its storage's reference count, which
    /// made 14 chunks slower than one thread.
    func run(chunk: Int) {
        let start = starts[chunk]
        let isLast = chunk == starts.count - 1
        let frameEnd = isLast ? frameCount : starts[chunk + 1].frame
        // The last chunk reads on past the frames; it stops after its last record.
        let byteEnd = isLast ? bytes.count : starts[chunk + 1].offset
        var local = decoder.borrowing(start.offset..<byteEnd, of: bytes)
        do {
            for index in start.frame..<frameEnd {
                (frames + index).initialize(to: try FrameMeta.decode(from: &local))
                initialized[chunk] += 1
            }
        } catch {
            return
        }
        ends[chunk] = start.offset + local.position
    }
}

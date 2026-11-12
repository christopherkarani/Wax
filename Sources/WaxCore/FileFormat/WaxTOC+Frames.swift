import Foundation

extension WaxTOC {
    /// Frame counts below this decode on the calling thread.
    static let parallelFrameDecodeThreshold = 8_192

    /// Decodes the TOC's `count` frame records, which start at `decoder`'s position, and
    /// leaves `decoder` just past them.
    ///
    /// Each record decodes its strings, checksums and metadata one after another, about
    /// 0.8 µs a frame: most of a 100k-frame store's open. Large TOCs decode in chunks on all
    /// cores instead.
    static func decodeFrames(count: Int, from decoder: inout BinaryDecoder) throws -> [FrameMeta] {
        let chunkCount = count >= parallelFrameDecodeThreshold
            ? min(ProcessInfo.processInfo.activeProcessorCount, count / 4_096)
            : 1
        return try decodeFrames(count: count, chunkCount: chunkCount, from: &decoder)
    }

    /// Decodes `count` frame records in up to `chunkCount` chunks at once.
    ///
    /// ``FrameMeta/skip(in:)``, which allocates nothing, first finds where each chunk starts.
    /// Each chunk then decodes from its own copy of its bytes: chunks reading one shared
    /// `Data` contend on its storage's reference count, which made 14 chunks slower than one
    /// thread. A chunk must decode all its frames and end where the next chunk starts.
    /// Anything else (a skip or chunk that fails, a boundary that disagrees) decodes again on
    /// one thread, so the frames and any error are exactly those of a sequential decode.
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

    /// The parallel decode, or `nil` (leaving `decoder` where it was) when any part of it fails.
    private static func decodeFramesInParallel(
        count: Int,
        chunkCount: Int,
        from decoder: inout BinaryDecoder
    ) -> [FrameMeta]? {
        let framesPerChunk = (count + chunkCount - 1) / chunkCount
        var probe = decoder
        var boundaries: [Int] = []
        boundaries.reserveCapacity(chunkCount + 1)
        do {
            for index in 0..<count {
                if index % framesPerChunk == 0 { boundaries.append(probe.position) }
                try FrameMeta.skip(in: &probe)
            }
        } catch {
            return nil
        }
        boundaries.append(probe.position)

        var decoded = false
        let frames = [FrameMeta](unsafeUninitializedCapacity: count) { buffer, initializedCount in
            let chunks = boundaries.count - 1
            let initialized = UnsafeMutableBufferPointer<Int>.allocate(capacity: chunks)
            initialized.initialize(repeating: 0)
            defer { initialized.deallocate() }
            let ended = UnsafeMutableBufferPointer<Bool>.allocate(capacity: chunks)
            ended.initialize(repeating: false)
            defer { ended.deallocate() }
            let work = FrameChunkDecode(
                decoder: decoder,
                boundaries: boundaries,
                framesPerChunk: framesPerChunk,
                frameCount: count,
                frames: buffer.baseAddress!,
                initialized: initialized.baseAddress!,
                ended: ended.baseAddress!
            )
            DispatchQueue.concurrentPerform(iterations: chunks) { work.run(chunk: $0) }

            if ended.allSatisfy({ $0 }) {
                decoded = true
                initializedCount = count
                return
            }
            for chunk in 0..<chunks {
                let start = work.frameRange(chunk: chunk).lowerBound
                (buffer.baseAddress! + start).deinitialize(count: initialized[chunk])
            }
            initializedCount = 0
        }
        guard decoded, (try? decoder.seek(to: boundaries[boundaries.count - 1])) != nil else { return nil }
        return frames
    }
}

/// One TOC decode's chunk work, shared by the `concurrentPerform` workers.
///
/// `@unchecked Sendable`: the pointers reference buffers the caller keeps alive for the
/// whole join, and each worker writes only its own chunk's frames and its own `initialized`
/// and `ended` slots. The decoder is only copied from.
private final class FrameChunkDecode: @unchecked Sendable {
    let decoder: BinaryDecoder
    let boundaries: [Int]
    let framesPerChunk: Int
    let frameCount: Int
    let frames: UnsafeMutablePointer<FrameMeta>
    let initialized: UnsafeMutablePointer<Int>
    let ended: UnsafeMutablePointer<Bool>

    init(
        decoder: BinaryDecoder,
        boundaries: [Int],
        framesPerChunk: Int,
        frameCount: Int,
        frames: UnsafeMutablePointer<FrameMeta>,
        initialized: UnsafeMutablePointer<Int>,
        ended: UnsafeMutablePointer<Bool>
    ) {
        self.decoder = decoder
        self.boundaries = boundaries
        self.framesPerChunk = framesPerChunk
        self.frameCount = frameCount
        self.frames = frames
        self.initialized = initialized
        self.ended = ended
    }

    func frameRange(chunk: Int) -> Range<Int> {
        (chunk * framesPerChunk)..<min(frameCount, (chunk + 1) * framesPerChunk)
    }

    /// Decodes the chunk's frames in place, counting each in `initialized[chunk]`, and sets
    /// `ended[chunk]` when all of them decoded and the last one ends on the next boundary.
    func run(chunk: Int) {
        var local = decoder.copying(boundaries[chunk]..<boundaries[chunk + 1])
        do {
            for index in frameRange(chunk: chunk) {
                (frames + index).initialize(to: try FrameMeta.decode(from: &local))
                initialized[chunk] += 1
            }
        } catch {
            return
        }
        ended[chunk] = local.remainingByteCount == 0
    }
}

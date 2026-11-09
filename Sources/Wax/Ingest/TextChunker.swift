import Foundation

package enum TextChunker {
    /// Deterministic, token-aware chunking using the same encoding as Fast RAG.
    /// - Returns: array of chunk strings (UTF-8), or `[text]` when it fits.
    package static func chunk(text: String, strategy: ChunkingStrategy) async -> [String] {
        switch strategy {
        case let .tokenCount(targetTokens, overlapTokens):
            return await tokenCountChunk(text: text, targetTokens: targetTokens, overlapTokens: overlapTokens)
        }
    }

    /// Stream chunked text without materializing the full chunk list in memory.
    package static func stream(text: String, strategy: ChunkingStrategy) -> AsyncStream<String> {
        switch strategy {
        case let .tokenCount(targetTokens, overlapTokens):
            return tokenCountChunkStream(text: text, targetTokens: targetTokens, overlapTokens: overlapTokens)
        }
    }

    private static func tokenCountChunk(text: String, targetTokens: Int, overlapTokens: Int) async -> [String] {
        let cappedTarget = max(1, targetTokens)
        let cappedOverlap = max(0, overlapTokens)

        let counter: TokenCounter
        do {
            counter = try await TokenCounter.shared()
        } catch {
            WaxDiagnostics.logSwallowed(
                error,
                context: "text chunker token counter init",
                fallback: "character-preserving unsplit text"
            )
            return [text]
        }
        let tokens = await counter.encode(text)
        if tokens.count <= cappedTarget {
            return [text]
        }

        let ranges = await scalarAligned(
            tokenCountChunkRanges(tokenCount: tokens.count, targetTokens: cappedTarget, overlapTokens: cappedOverlap),
            in: tokens,
            counter: counter
        )
        var chunks: [String] = []
        chunks.reserveCapacity(ranges.count)
        for range in ranges {
            let slice = Array(tokens[range])
            let chunk = await counter.decode(slice)
            if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chunks.append(chunk)
            }
        }
        if chunks.isEmpty {
            return [text]
        }
        return chunks
    }

    private static func tokenCountChunkStream(
        text: String,
        targetTokens: Int,
        overlapTokens: Int
    ) -> AsyncStream<String> {
        let cappedTarget = max(1, targetTokens)
        let cappedOverlap = max(0, overlapTokens)

        return AsyncStream { continuation in
            Task {
                let counter: TokenCounter
                do {
                    counter = try await TokenCounter.shared()
                } catch {
                    WaxDiagnostics.logSwallowed(
                        error,
                        context: "text chunker stream token counter init",
                        fallback: "stream original unsplit text"
                    )
                    continuation.yield(text)
                    continuation.finish()
                    return
                }
                let tokens = await counter.encode(text)
                if tokens.count <= cappedTarget {
                    continuation.yield(text)
                    continuation.finish()
                    return
                }

                let ranges = await scalarAligned(
                    tokenCountChunkRanges(tokenCount: tokens.count, targetTokens: cappedTarget, overlapTokens: cappedOverlap),
                    in: tokens,
                    counter: counter
                )

                for range in ranges {
                    let slice = Array(tokens[range])
                    let chunk = await counter.decode(slice)
                    if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        continuation.yield(chunk)
                    }
                }
                continuation.finish()
            }
        }
    }

    /// Re-splits every chunk whose `inputTokenCount` exceeds `limit` until each piece fits, so an
    /// embedder that truncates its input at `limit` tokens still sees all of the text. Pieces of a
    /// split chunk do not overlap; they concatenate back to that chunk. A chunk that cannot be
    /// split further (a single cl100k token or character) is kept as is.
    package static func fit(
        _ chunks: [String],
        inputTokenLimit limit: Int,
        inputTokenCount: (String) -> Int
    ) async -> [String] {
        guard limit > 0, let counter = try? await TokenCounter.shared() else { return chunks }
        var fitted: [String] = []
        fitted.reserveCapacity(chunks.count)
        var pending = Array(chunks.reversed())
        while let chunk = pending.popLast() {
            let count = inputTokenCount(chunk)
            let tokens = count > limit ? await counter.encode(chunk) : []
            guard tokens.count > 1 else {
                fitted.append(chunk)
                continue
            }
            // Size pieces by the observed token ratio; every piece is strictly shorter, so this ends.
            let target = max(1, min(tokens.count - 1, tokens.count * limit / count))
            let ranges = await scalarAligned(
                tokenCountChunkRanges(tokenCount: tokens.count, targetTokens: target, overlapTokens: 0),
                in: tokens,
                counter: counter
            )
            // One multi-token character has no inner scalar boundary to cut at.
            guard ranges.count > 1 else {
                fitted.append(chunk)
                continue
            }
            var pieces: [String] = []
            for range in ranges {
                pieces.append(await counter.decode(Array(tokens[range])))
            }
            pending.append(contentsOf: pieces.reversed())
        }
        let nonEmpty = fitted.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return nonEmpty.isEmpty ? chunks : nonEmpty
    }

    /// Moves each range bound forward to the next token that starts a Unicode scalar, so no
    /// piece begins or ends inside a multi-byte character (byte-level BPE splits CJK and emoji
    /// across tokens). Bounds already on scalar boundaries do not move, adjacent ranges stay
    /// adjacent, and ranges that collapse or repeat the previous one are dropped.
    private static func scalarAligned(
        _ ranges: [Range<Int>],
        in tokens: [UInt32],
        counter: TokenCounter
    ) async -> [Range<Int>] {
        var aligned: [Range<Int>] = []
        aligned.reserveCapacity(ranges.count)
        for range in ranges {
            let start = await counter.scalarBoundary(atOrAfter: range.lowerBound, in: tokens)
            let end = await counter.scalarBoundary(atOrAfter: range.upperBound, in: tokens)
            if start < end, aligned.last != start..<end {
                aligned.append(start..<end)
            }
        }
        return aligned
    }

    private static func tokenCountChunkRanges(
        tokenCount: Int,
        targetTokens: Int,
        overlapTokens: Int
    ) -> [Range<Int>] {
        guard tokenCount > 0 else { return [] }
        let cappedTarget = max(1, targetTokens)
        let cappedOverlap = max(0, overlapTokens)
        if tokenCount <= cappedTarget {
            return [0..<tokenCount]
        }

        var ranges: [Range<Int>] = []
        var start = 0
        while start < tokenCount {
            let end = min(start + cappedTarget, tokenCount)
            ranges.append(start..<end)
            if end == tokenCount { break }
            let proposed = end - cappedOverlap
            let nextStart = proposed > start ? proposed : end
            if nextStart <= start { break } // safety
            start = nextStart
        }
        return ranges
    }
}

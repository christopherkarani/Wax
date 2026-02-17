import Foundation

public enum TextChunker {
    /// Deterministic, token-aware chunking using the same encoding as Fast RAG.
    /// - Returns: array of chunk strings (UTF-8), or `[text]` when it fits.
    public static func chunk(text: String, strategy: ChunkingStrategy) async -> [String] {
        switch strategy {
        case let .tokenCount(targetTokens, overlapTokens):
            return await tokenCountChunk(text: text, targetTokens: targetTokens, overlapTokens: overlapTokens)
        }
    }

    /// Stream chunked text without materializing the full chunk list in memory.
    public static func stream(text: String, strategy: ChunkingStrategy) -> AsyncStream<String> {
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

        let ranges = tokenCountChunkRanges(
            tokenCount: tokens.count,
            targetTokens: cappedTarget,
            overlapTokens: cappedOverlap
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

                let ranges = tokenCountChunkRanges(
                    tokenCount: tokens.count,
                    targetTokens: cappedTarget,
                    overlapTokens: cappedOverlap
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

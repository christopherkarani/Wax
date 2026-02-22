import Testing
import Wax

@Test
func tokenChunkingIsDeterministic() async {
    let text = "Swift is a fast and safe systems programming language.".repeating(times: 5)
    let strategy = ChunkingStrategy.tokenCount(targetTokens: 12, overlapTokens: 4)

    let first = await TextChunker.chunk(text: text, strategy: strategy)
    let second = await TextChunker.chunk(text: text, strategy: strategy)

    #expect(first == second)
    #expect(first.count > 1)
}

@Test
func tokenChunkingHonorsOverlapStrideWhenPossible() async throws {
    let text = "Swift concurrency uses actors and tasks.".repeating(times: 20)
    let strategy = ChunkingStrategy.tokenCount(targetTokens: 10, overlapTokens: 3)

    let chunks = await TextChunker.chunk(text: text, strategy: strategy)
    #expect(chunks.count >= 2)

    let counter = try await TokenCounter()
    let tokens = await counter.encode(text)
    #expect(tokens.count > 10)

    let expected0 = await counter.decode(Array(tokens[0..<10]))
    let expected1 = await counter.decode(Array(tokens[7..<min(17, tokens.count)]))

    #expect(chunks[0] == expected0)
    #expect(chunks[1] == expected1)

    let chunk0Tokens = await counter.encode(chunks[0])
    let chunk1Tokens = await counter.encode(chunks[1])
    #expect(Array(chunk0Tokens.suffix(3)) == Array(chunk1Tokens.prefix(3)))
}

@Test
func tokenChunkingDisablesOverlapWhenOverlapWouldStall() async throws {
    let text = "Swift concurrency uses actors and tasks.".repeating(times: 20)
    let strategy = ChunkingStrategy.tokenCount(targetTokens: 10, overlapTokens: 10)

    let chunks = await TextChunker.chunk(text: text, strategy: strategy)
    #expect(chunks.count >= 2)

    let counter = try await TokenCounter()
    let tokens = await counter.encode(text)
    #expect(tokens.count > 10)

    let expected1 = await counter.decode(Array(tokens[10..<min(20, tokens.count)]))
    #expect(chunks[1] == expected1)
}

@Test
func tokenChunkingStreamMatchesEagerChunks() async throws {
    let text = "Swift concurrency uses actors and tasks.".repeating(times: 12)
    let strategy = ChunkingStrategy.tokenCount(targetTokens: 14, overlapTokens: 4)

    let eager = await TextChunker.chunk(text: text, strategy: strategy)
    var streamed: [String] = []
    for await chunk in TextChunker.stream(text: text, strategy: strategy) {
        streamed.append(chunk)
    }

    #expect(streamed == eager)
}

@Test
func tokenChunkingShortTextReturnsSingleChunk() async {
    let text = "short deterministic text"
    let strategy = ChunkingStrategy.tokenCount(targetTokens: 64, overlapTokens: 8)
    let chunks = await TextChunker.chunk(text: text, strategy: strategy)
    #expect(chunks == [text])
}

@Test
func tokenChunkingClampsInvalidTargetAndOverlap() async throws {
    let text = "deterministic chunking boundary case ".repeating(times: 30)
    let clamped = await TextChunker.chunk(
        text: text,
        strategy: .tokenCount(targetTokens: 0, overlapTokens: -5)
    )
    let explicit = await TextChunker.chunk(
        text: text,
        strategy: .tokenCount(targetTokens: 1, overlapTokens: 0)
    )
    #expect(clamped == explicit)
}

@Test
func tokenChunkingStreamShortTextYieldsOriginalOnly() async {
    let text = "stream me once"
    let strategy = ChunkingStrategy.tokenCount(targetTokens: 100, overlapTokens: 0)
    var streamed: [String] = []
    for await chunk in TextChunker.stream(text: text, strategy: strategy) {
        streamed.append(chunk)
    }
    #expect(streamed == [text])
}

private extension String {
    func repeating(times: Int) -> String {
        guard times > 1 else { return self }
        return Array(repeating: self, count: times).joined(separator: " ")
    }
}

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
func tokenChunkingWithOverlapNeverSplitsMultiByteCharacters() async throws {
    // Rare CJK (ext B) and emoji are several byte-level BPE tokens each, so token cuts land
    // inside them.
    let text = mixedScriptText(characters: 3_000, includeSpaces: true)
    #expect(text.count == 3_000)
    let tokenizer = try NativeBpeTokenizer()
    #expect(tokenizer.encode(text).contains { tokenizer.decode([$0]).contains("\u{FFFD}") })

    let strategy = ChunkingStrategy.tokenCount(targetTokens: 16, overlapTokens: 5)
    let chunks = await TextChunker.chunk(text: text, strategy: strategy)
    var streamed: [String] = []
    for await chunk in TextChunker.stream(text: text, strategy: strategy) {
        streamed.append(chunk)
    }

    #expect(chunks.count > 10)
    #expect(streamed == chunks)
    #expect(!chunks.contains { $0.contains("\u{FFFD}") })
    #expect(utf8Coverage(of: text, by: chunks) == text.utf8.count)
}

@Test
func fitPiecesJoinBackToTheChunkAcrossMultiByteCharacters() async throws {
    let text = mixedScriptText(characters: 400, includeSpaces: false)
    let tokenizer = try NativeBpeTokenizer()

    let pieces = await TextChunker.fit([text], inputTokenLimit: 8) { tokenizer.encode($0).count }

    #expect(pieces.count > 1)
    #expect(!pieces.contains { $0.contains("\u{FFFD}") })
    #expect(pieces.joined() == text)
}

@Test
func tokenChunkingCoversTextPastTheTokenizerByteCap() async throws {
    let marker = "zqxtailmarker"
    let sentence = "Swift concurrency uses actors and tasks. "
    let filler = String(repeating: sentence, count: (8 * 1024 * 1024 + 512 * 1024) / sentence.utf8.count)
    #expect(filler.utf8.count > TokenCounter.maxTokenizationBytes)
    let tail = String(repeating: sentence, count: 50 * 1024 / sentence.utf8.count)
    let text = filler + marker + " " + tail
    #expect(text.utf8.count - filler.utf8.count < 100 * 1024)

    let strategy = ChunkingStrategy.tokenCount(targetTokens: 400, overlapTokens: 40)
    let chunks = await TextChunker.chunk(text: text, strategy: strategy)
    #expect(chunks.contains { $0.contains(marker) })

    var streamedMarker = false
    for await chunk in TextChunker.stream(text: text, strategy: strategy) where chunk.contains(marker) {
        streamedMarker = true
    }
    #expect(streamedMarker)
}

/// Deterministic text drawn from CJK (BMP and ext B) and emoji, `characters` long.
private func mixedScriptText(characters: Int, includeSpaces: Bool) -> String {
    var pool: [Character] = ["漢", "字", "龘", "鱻", "齉", "𠜎", "𪚥", "𤭢", "🦀", "🧬", "🪐", "😀", "🫠", "語"]
    if includeSpaces { pool.append(" ") }
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    var text = ""
    var previous: Character = " "
    while text.count < characters {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let next = pool[Int((state >> 33) % UInt64(pool.count))]
        if next == " " && (previous == " " || text.isEmpty) { continue }
        text.append(next)
        previous = next
    }
    return text
}

/// Bytes of `text` covered from its start by `chunks`, each found in order as an exact UTF-8
/// slice no later than the end of the coverage so far.
private func utf8Coverage(of text: String, by chunks: [String]) -> Int {
    let bytes = Array(text.utf8)
    var covered = 0
    var searchFrom = 0
    for chunk in chunks {
        let needle = Array(chunk.utf8)
        guard !needle.isEmpty, searchFrom + needle.count <= bytes.count else { return covered }
        let start = (searchFrom...(bytes.count - needle.count)).first {
            bytes[$0..<($0 + needle.count)].elementsEqual(needle)
        }
        guard let start, start <= covered else { return covered }
        covered = max(covered, start + needle.count)
        searchFrom = start
    }
    return covered
}

private extension String {
    func repeating(times: Int) -> String {
        guard times > 1 else { return self }
        return Array(repeating: self, count: times).joined(separator: " ")
    }
}

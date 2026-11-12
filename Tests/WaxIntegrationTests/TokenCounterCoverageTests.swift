import Foundation
import Testing
@testable import Wax

// MARK: - isPreloaded

@Test func tokenCounterIsPreloadedDefaultEncoding() async {
    let loaded = await TokenCounter.isPreloaded()
    // The value depends on whether another test loaded it; exercise the code path
    _ = loaded
}

// MARK: - Diagnostic static methods

@Test func tokenCounterBpeCacheStatsReturnsSnapshot() async {
    let stats = await TokenCounter._bpeCacheStats()
    #expect(stats.loadCount >= 0)
}

@Test func tokenCounterResetBpeCacheStats() async {
    // Just exercise the reset code path; don't assert loadCount because
    // the shared static cache may be loaded by parallel tests.
    await TokenCounter._resetBpeCacheStats()
    _ = await TokenCounter._bpeCacheStats()
}

@Test func tokenCounterComparisonStatsReturnsSnapshot() async {
    let stats = await TokenCounter._comparisonStats()
    // Default backend is tiktoken, not compare, so mismatches should be 0
    #expect(stats.mismatches == 0)
}

// MARK: - truncateCounted

@Test func tokenCounterTruncateCountedMatchesTruncateThenCount() async throws {
    let counter = try await TokenCounter()
    let texts: [String] = [
        "Hello",
        "The quick brown fox jumps over the lazy dog, then naps in the afternoon sun.",
        String(repeating: "naïve café déjà vu 東京 🚀 ", count: 40),
    ]
    for text in texts {
        for maxTokens in [1, 3, 8, 17, 4_096] {
            let truncated: String = await counter.truncate(text, maxTokens: maxTokens)
            let expectedTokens: Int = await counter.count(truncated)
            // Twice: the second call reads the encoding the first one cached.
            for _ in 0..<2 {
                let counted: (text: String, tokens: Int) = await counter.truncateCounted(text, maxTokens: maxTokens)
                #expect(counted.text == truncated)
                #expect(counted.tokens == expectedTokens)
            }
        }
    }
}

// MARK: - countBatch (sequential path: <= 4 items)

@Test func tokenCounterCountBatchSmall() async throws {
    let counter = try await TokenCounter()
    let texts = ["Hello", "World", "Test"]
    let counts = await counter.countBatch(texts)
    #expect(counts.count == 3)
    for c in counts {
        #expect(c > 0)
    }
}

// MARK: - countBatch (parallel path: > 4 items)

@Test func tokenCounterCountBatchLargeTriggersParallel() async throws {
    let counter = try await TokenCounter()
    let texts = (0..<8).map { "Sample text number \($0)" }
    let counts = await counter.countBatch(texts)
    #expect(counts.count == 8)
    for c in counts {
        #expect(c > 0)
    }
}

// MARK: - encodeBatch

@Test func tokenCounterEncodeBatchSmall() async throws {
    let counter = try await TokenCounter()
    let texts = ["Hello world", "Testing batch"]
    let encodings = await counter.encodeBatch(texts)
    #expect(encodings.count == 2)
    for enc in encodings {
        #expect(!enc.isEmpty)
    }
}

@Test func tokenCounterEncodeBatchLarge() async throws {
    let counter = try await TokenCounter()
    let texts = (0..<6).map { "Encoding text \($0) for batch" }
    let encodings = await counter.encodeBatch(texts)
    #expect(encodings.count == 6)
}

// MARK: - truncateBatch

@Test func tokenCounterTruncateBatchSmall() async throws {
    let counter = try await TokenCounter()
    let texts = ["This is some text", "Another text here"]
    let truncated = await counter.truncateBatch(texts, maxTokens: 2)
    #expect(truncated.count == 2)
    for t in truncated {
        #expect(!t.isEmpty)
    }
}

@Test func tokenCounterTruncateBatchLarge() async throws {
    let counter = try await TokenCounter()
    let texts = (0..<6).map { "Longer text for truncation testing \($0) with enough words" }
    let truncated = await counter.truncateBatch(texts, maxTokens: 3)
    #expect(truncated.count == 6)
}

@Test func tokenCounterTruncateBatchZeroMaxReturnsEmpty() async throws {
    let counter = try await TokenCounter()
    let texts = ["hello", "world"]
    let truncated = await counter.truncateBatch(texts, maxTokens: 0)
    #expect(truncated.count == 2)
    for t in truncated {
        #expect(t.isEmpty)
    }
}

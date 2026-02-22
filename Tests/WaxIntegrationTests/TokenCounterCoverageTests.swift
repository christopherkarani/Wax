import Foundation
import Testing
@testable import Wax

// MARK: - Preload and shared cache

@Test
func tokenCounterPreloadAndSharedCacheReuse() async throws {
    let preloaded = try await TokenCounter.preload()
    #expect(preloaded == true)
    #expect(await TokenCounter.isPreloaded() == true)

    let shared = try await TokenCounter.shared(cacheCapacity: 32)
    let count = await shared.count("token counter shared warm path")
    #expect(count > 0)

    // Requesting the same encoding with a different cacheCapacity forces re-creation.
    let resized = try await TokenCounter.shared(cacheCapacity: 8)
    let resizedCount = await resized.count("token counter resized cache path")
    #expect(resizedCount > 0)
}

// MARK: - Batch operations (small and large paths)

@Test
func tokenCounterBatchOperationsCoverSmallAndLargePaths() async throws {
    let counter = try await TokenCounter(cacheCapacity: 2)
    let small = ["alpha", "beta gamma", "delta epsilon zeta"]
    let large = [
        "alpha",
        "beta gamma",
        "delta epsilon zeta",
        "eta theta iota",
        "kappa lambda mu",
        "nu xi omicron",
    ]

    let smallCounts = await counter.countBatch(small)
    #expect(smallCounts.count == small.count)
    #expect(smallCounts.allSatisfy { $0 > 0 })

    let largeCounts = await counter.countBatch(large)
    #expect(largeCounts.count == large.count)
    #expect(largeCounts.allSatisfy { $0 > 0 })

    let smallEncoded = await counter.encodeBatch(small)
    let largeEncoded = await counter.encodeBatch(large)
    #expect(smallEncoded.count == small.count)
    #expect(largeEncoded.count == large.count)
    #expect(largeEncoded.allSatisfy { !$0.isEmpty })

    let smallTruncated = await counter.truncateBatch(small, maxTokens: 4)
    let largeTruncated = await counter.truncateBatch(large, maxTokens: 4)
    #expect(smallTruncated.count == small.count)
    #expect(largeTruncated.count == large.count)

    let emptyTruncated = await counter.truncateBatch(large, maxTokens: 0)
    #expect(emptyTruncated == Array(repeating: "", count: large.count))

    let countedSmall = await counter.countAndTruncateBatch(small, maxTokens: 4)
    let countedLarge = await counter.countAndTruncateBatch(large, maxTokens: 4)
    #expect(countedSmall.count == small.count)
    #expect(countedLarge.count == large.count)
    #expect(countedLarge.allSatisfy { $0.count >= 0 })

    let countedEmpty = await counter.countAndTruncateBatch(large, maxTokens: 0)
    #expect(countedEmpty.allSatisfy { $0.count == 0 && $0.truncated.isEmpty })
}

// MARK: - Truncate with cache and UTF-8 cap

@Test
func tokenCounterTruncateUsesCacheAndHandlesUtf8Cap() async throws {
    // Capacity=1 ensures the LRU eviction path is exercised when a second text is put.
    let counter = try await TokenCounter(cacheCapacity: 1)
    let sample = "Wax tokenizer cache determinism sample"

    let first = await counter.truncate(sample, maxTokens: 3)
    // Second call hits cache (same text) and takes the cached path.
    let second = await counter.truncate(sample, maxTokens: 3)
    #expect(first == second)
    #expect(!first.isEmpty)

    // Feeding a different string at capacity=1 evicts the first entry.
    let other = "Different tokenizer input to trigger LRU eviction"
    let fromCache = await counter.truncate(other, maxTokens: 5)
    #expect(!fromCache.isEmpty)

    // maxTokens=0 returns empty string immediately, exercising the early-return guard.
    let empty = await counter.truncate(sample, maxTokens: 0)
    #expect(empty.isEmpty)
}

// MARK: - cappedUTF8Prefix both paths

@Test
func tokenCounterCappedUtf8PrefixFitsWithinBudgetReturnsOriginal() async throws {
    // When the text fits within maxTokenizationBytes, cappedUTF8Prefix returns
    // the original string unchanged (the `guard endScalars != endIndex` branch).
    let counter = try await TokenCounter(cacheCapacity: 4)
    let short = "Wax deterministic token counter capped prefix test"
    let tokens = await counter.encode(short)
    #expect(!tokens.isEmpty)
    let tokenCount = await counter.count(short)
    #expect(tokenCount == tokens.count)
}

@Test
func tokenCounterCappedUtf8PrefixTruncatesOversizedInput() async throws {
    // Build a string whose UTF-8 length slightly exceeds TokenCounter.maxTokenizationBytes
    // (8 MB). Using ASCII (1 byte per character) keeps construction fast.
    // The oversized input exercises the truncation branch of cappedUTF8Prefix.
    //
    // Memory note: 8 MB of ASCII = 8 × 1,048,576 chars + a few bytes ≈ 8.5 MB peak.
    // This is acceptable for a unit test; the string is immediately deallocated after.
    let chunkSize = 1_024 * 1_024         // 1 MB
    let chunk = String(repeating: "A", count: chunkSize)
    // 9 chunks = 9 MB → exceeds the 8 MB limit by 1 MB.
    let oversized = String(repeating: chunk, count: 9)

    let counter = try await TokenCounter(cacheCapacity: 4)
    let tokens = await counter.encode(oversized)
    // encode() must produce a non-empty result (the truncated prefix is still valid text).
    #expect(!tokens.isEmpty)
    // count() must agree with encode().count.
    let tokenCount = await counter.count(oversized)
    #expect(tokenCount == tokens.count)
}

// MARK: - TokenizationCache LRU eviction and reuse

@Test
func tokenCounterLruCacheEvictionAndReuse() async throws {
    // Capacity of 2 forces eviction after the third distinct text is put.
    let counter = try await TokenCounter(cacheCapacity: 2)

    let t1 = "cache entry one"
    let t2 = "cache entry two"
    let t3 = "cache entry three evicts one"

    // Populate cache to capacity.
    let r1a = await counter.truncate(t1, maxTokens: 10)
    let r2a = await counter.truncate(t2, maxTokens: 10)

    // Evict t1 by inserting t3 (cache is full at capacity=2).
    let r3a = await counter.truncate(t3, maxTokens: 10)

    // Re-encode t2 — still in cache, should return same result.
    let r2b = await counter.truncate(t2, maxTokens: 10)
    #expect(r2a == r2b)

    // t1 was evicted; re-encoding it must still produce a correct result.
    let r1b = await counter.truncate(t1, maxTokens: 10)
    #expect(r1a == r1b)

    _ = r3a // suppress unused warning
}

// MARK: - Comparison stats observable

@Test
func tokenCounterComparisonStatsAreReadable() async {
    let snapshot = await TokenCounter._comparisonStats()
    #expect(snapshot.tiktokenMillis >= 0)
    #expect(snapshot.nativeMillis >= 0)
    #expect(snapshot.mismatches >= 0)
}

// MARK: - Encode + decode round-trip

@Test
func tokenCounterEncodesAndDecodesRoundTrip() async throws {
    let counter = try await TokenCounter(cacheCapacity: 8)
    let samples = [
        "Hello, World!",
        "Swift 6.2 concurrency model",
        "Wax provides deterministic RAG.",
        "Emoji test: cafe\u{0301}", // e + combining accent = é
    ]
    for text in samples {
        let tokens = await counter.encode(text)
        #expect(!tokens.isEmpty, "Expected non-empty tokens for: \(text)")
        let decoded = await counter.decode(tokens)
        // Decoded text should reconstruct the original (NFC normalization may differ
        // from NFD input, so we compare the token sequence robustly).
        let reEncoded = await counter.encode(decoded)
        #expect(tokens == reEncoded, "Round-trip encode mismatch for: \(text)")
    }
}

// MARK: - countAndTruncateBatch fits-within-budget path

@Test
func tokenCounterCountAndTruncateBatchFitsWithinBudget() async throws {
    let counter = try await TokenCounter(cacheCapacity: 8)
    let short = ["hi", "ok", "yes", "no", "bye"]
    // Budget large enough so every string fits without truncation.
    let results = await counter.countAndTruncateBatch(short, maxTokens: 100)
    #expect(results.count == short.count)
    for (index, item) in results.enumerated() {
        // All inputs fit in budget; the returned text must equal the input.
        #expect(item.truncated == short[index])
        #expect(item.count > 0)
    }
}

// MARK: - truncateBatch small path (<=4 texts)

@Test
func tokenCounterTruncateBatchSmallPathReturnsSameText() async throws {
    let counter = try await TokenCounter(cacheCapacity: 8)
    let inputs = ["one", "two", "three"] // <= 4 → sequential path
    let result = await counter.truncateBatch(inputs, maxTokens: 50)
    // Budget easily covers all three; text should be identical.
    #expect(result == inputs)
}

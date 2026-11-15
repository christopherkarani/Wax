import Foundation

/// Deterministic token counter backed by the built-in NativeBpeTokenizer.
/// Optimized with LRU caching to avoid redundant tokenization operations.
package actor TokenCounter {
    package enum Encoding: String, Sendable {
        case cl100kBase = "cl100k_base"
    }

    struct BpeCacheStats: Sendable {
        var loadCount: Int = 0
    }

    struct ComparisonSnapshot: Sendable {
        var tiktokenMillis: Double = 0
        var nativeMillis: Double = 0
        var mismatches: Int = 0
    }

    private actor NativeBpeCache {
        private var cache: [Encoding: NativeBpeTokenizer] = [:]
        private var stats = BpeCacheStats()

        func tokenizer(for encoding: Encoding) throws -> NativeBpeTokenizer {
            if let cached = cache[encoding] { return cached }
            let nativeEncoding: NativeBpeTokenizer.Encoding = .cl100kBase
            let loaded = try NativeBpeTokenizer(encoding: nativeEncoding)
            cache[encoding] = loaded
            stats.loadCount += 1
            return loaded
        }

        func isLoaded(encoding: Encoding) -> Bool {
            cache[encoding] != nil
        }

        func snapshotStats() -> BpeCacheStats { stats }

        func resetStats() {
            stats = BpeCacheStats()
        }
    }

    private static let sharedCache = TokenCounterCache()
    private static let nativeBpeCache = NativeBpeCache()
    package static let maxTokenizationBytes = 8 * 1024 * 1024

    private let tokenizer: NativeBpeTokenizer
    private let encodingCache: TokenizationCache

    package init(encoding: Encoding = .cl100kBase, cacheCapacity: Int = 1024) async throws {
        self.tokenizer = try await Self.nativeBpeCache.tokenizer(for: encoding)
        self.encodingCache = TokenizationCache(capacity: cacheCapacity)
    }

    package static func shared(encoding: Encoding = .cl100kBase, cacheCapacity: Int = 1024) async throws -> TokenCounter {
        try await sharedCache.counter(for: encoding, cacheCapacity: cacheCapacity)
    }

    /// Preload tokenizer in the background to eliminate cold start latency.
    /// Call this at app launch to warm up the tokenizer before it's needed.
    ///
    /// Usage:
    /// ```swift
    /// Task.detached(priority: .utility) {
    ///     try? await TokenCounter.preload()
    /// }
    /// ```
    @discardableResult
    package static func preload(encoding: Encoding = .cl100kBase) async throws -> Bool {
        _ = try await nativeBpeCache.tokenizer(for: encoding)
        return true
    }

    /// Check if the tokenizer is already loaded (no cold start penalty).
    package static func isPreloaded(encoding: Encoding = .cl100kBase) async -> Bool {
        await nativeBpeCache.isLoaded(encoding: encoding)
    }

    static func _bpeCacheStats() async -> BpeCacheStats {
        await nativeBpeCache.snapshotStats()
    }

    static func _resetBpeCacheStats() async {
        await nativeBpeCache.resetStats()
    }

    static func _comparisonStats() async -> ComparisonSnapshot {
        // Only one backend now — no comparison stats.
        ComparisonSnapshot()
    }

    package func count(_ text: String) -> Int {
        encode(text).count
    }

    package func truncate(_ text: String, maxTokens: Int) async -> String {
        guard maxTokens > 0 else { return "" }

        let tokens = encodingCache.tokens(for: text, orEncode: encode)
        if tokens.count <= maxTokens {
            return text
        }
        let sliced = Array(tokens.prefix(maxTokens))
        return decode(sliced)
    }

    /// `truncate(text, maxTokens:)` and `count` of its result, encoding `text` once instead
    /// of twice when it already fits.
    package func truncateCounted(_ text: String, maxTokens: Int) async -> (text: String, tokens: Int) {
        guard maxTokens > 0 else { return ("", count("")) }
        let tokens = encodingCache.tokens(for: text, orEncode: encode)
        // `count(text)` is `encode(text).count`, which is what the cache holds for `text`.
        if tokens.count <= maxTokens {
            return (text, tokens.count)
        }
        // A decoded prefix can re-encode to a different length, so count it as `count` would.
        let truncated = decode(Array(tokens.prefix(maxTokens)))
        return (truncated, count(truncated))
    }

    /// Nonisolated: the tokenizer is safe for concurrent reads, so chunkers encoding in
    /// parallel do not queue on this actor.
    nonisolated package func encode(_ text: String) -> [UInt32] {
        let capped = Self.cappedUTF8Prefix(text, maxBytes: Self.maxTokenizationBytes)
        return tokenizer.encode(capped)
    }

    nonisolated package func decode(_ tokens: [UInt32]) -> String {
        tokenizer.decode(tokens)
    }

    // MARK: - Batch Operations (Optimized)

    /// Thread-safe encoding using nonisolated access to the tokenizer.
    /// NativeBpeTokenizer is @unchecked Sendable and safe for concurrent reads.
    nonisolated private func encodeNonisolated(_ text: String, tokenizer: NativeBpeTokenizer) -> [UInt32] {
        let capped = Self.cappedUTF8Prefix(text, maxBytes: Self.maxTokenizationBytes)
        return tokenizer.encode(capped)
    }

    /// Thread-safe decoding using nonisolated access to the tokenizer.
    nonisolated private func decodeNonisolated(_ tokens: [UInt32], tokenizer: NativeBpeTokenizer) -> String {
        tokenizer.decode(tokens)
    }

    /// Count tokens for multiple texts - uses parallel processing for better throughput.
    package func countBatch(_ texts: [String]) async -> [Int] {
        // For small batches, sequential is faster due to overhead
        guard texts.count > 4 else {
            return texts.map { encode($0).count }
        }

        let localTokenizer = tokenizer

        var results = [Int](repeating: 0, count: texts.count)

        await withTaskGroup(of: (Int, Int).self) { group in
            for (index, text) in texts.enumerated() {
                group.addTask {
                    (index, self.encodeNonisolated(text, tokenizer: localTokenizer).count)
                }
            }

            for await (index, count) in group {
                results[index] = count
            }
        }

        return results
    }

    /// Encode multiple texts to tokens - uses parallel processing.
    package func encodeBatch(_ texts: [String]) async -> [[UInt32]] {
        guard texts.count > 4 else {
            return texts.map { encode($0) }
        }

        let localTokenizer = tokenizer
        var results = Array<[UInt32]>(repeating: [], count: texts.count)

        await withTaskGroup(of: (Int, [UInt32]).self) { group in
            for (index, text) in texts.enumerated() {
                group.addTask {
                    (index, self.encodeNonisolated(text, tokenizer: localTokenizer))
                }
            }

            for await (index, encoded) in group {
                results[index] = encoded
            }
        }

        return results
    }

    /// Truncate multiple texts to max tokens - optimized with parallel processing.
    package func truncateBatch(_ texts: [String], maxTokens: Int) async -> [String] {
        guard maxTokens > 0 else {
            return [String](repeating: "", count: texts.count)
        }

        // For small batches, use simple sequential processing
        guard texts.count > 4 else {
            var results: [String] = []
            results.reserveCapacity(texts.count)
            for text in texts {
                results.append(await truncate(text, maxTokens: maxTokens))
            }
            return results
        }

        let localTokenizer = tokenizer

        // Batch encode all texts first (parallel)
        let allTokens = await encodeBatch(texts)

        var results = [String](repeating: "", count: texts.count)

        await withTaskGroup(of: (Int, String).self) { group in
            for (index, tokens) in allTokens.enumerated() {
                group.addTask {
                    if tokens.count <= maxTokens {
                        return (index, texts[index])
                    }
                    let sliced = Array(tokens.prefix(maxTokens))
                    return (index, self.decodeNonisolated(sliced, tokenizer: localTokenizer))
                }
            }

            for await (index, value) in group {
                results[index] = value
            }
        }

        return results
    }

    /// Optimized batch count and truncate - single pass for both operations.
    package func countAndTruncateBatch(_ texts: [String], maxTokens: Int) async -> [(count: Int, truncated: String)] {
        guard maxTokens > 0 else {
            return texts.map { _ in (count: 0, truncated: "") }
        }

        // For small batches, sequential processing is faster than task-group setup.
        guard texts.count > 4 else {
            return texts.map { text in
                let tokens = encode(text)
                if tokens.count <= maxTokens {
                    return (count: tokens.count, truncated: text)
                }
                let sliced = Array(tokens.prefix(maxTokens))
                return (count: maxTokens, truncated: decode(sliced))
            }
        }

        let localTokenizer = tokenizer
        var results = [(count: Int, truncated: String)](repeating: (count: 0, truncated: ""), count: texts.count)

        // Single TaskGroup pass: encode and truncate in one child task per input.
        await withTaskGroup(of: (Int, (count: Int, truncated: String)).self) { group in
            for (index, text) in texts.enumerated() {
                group.addTask {
                    let tokens = self.encodeNonisolated(text, tokenizer: localTokenizer)
                    let count = tokens.count
                    if count <= maxTokens {
                        return (index, (count: count, truncated: text))
                    }
                    let sliced = Array(tokens.prefix(maxTokens))
                    let truncated = self.decodeNonisolated(sliced, tokenizer: localTokenizer)
                    return (index, (count: maxTokens, truncated: truncated))
                }
            }

            for await (index, entry) in group {
                results[index] = entry
            }
        }

        return results
    }

    private static func cappedUTF8Prefix(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }

        var bytes = 0
        var endScalars = text.unicodeScalars.startIndex
        var idx = endScalars
        while idx < text.unicodeScalars.endIndex {
            let scalar = text.unicodeScalars[idx]
            let scalarBytes = scalar.utf8.count
            if bytes + scalarBytes > maxBytes { break }
            bytes += scalarBytes
            idx = text.unicodeScalars.index(after: idx)
            endScalars = idx
        }

        guard endScalars != text.unicodeScalars.endIndex else { return text }
        let end = endScalars.samePosition(in: text) ?? text.endIndex
        return String(text[..<end])
    }
}

/// LRU cache for tokenization results to avoid redundant encoding operations.
/// Owned by one `TokenCounter` and used only on its executor, so a lookup is a call rather
/// than an actor hop.
///
/// Entries live in slots linked by index, so a hit hashes its key once and an insert at
/// most three times (lookup, insert, evicting the oldest). Keys are whole texts, often
/// hundreds of bytes, so each hash is a real cost; linking neighbours by key rehashed up
/// to eight of them per insert.
final class TokenizationCache {
    /// A text compared and hashed by its UTF-8 bytes. Tokens come from the bytes, while
    /// `String` equality is canonical equivalence: "caf\u{E9}" and "cafe\u{301}" are equal
    /// strings with 2 and 3 tokens. The bytes are hashed once, when the key is made, since
    /// a miss looks the key up, inserts it and later evicts it.
    private struct UTF8Key: Hashable {
        let text: String
        let bytesHash: Int

        init(_ text: String) {
            self.text = text
            var hasher = Hasher()
            let hashed: Void? = text.utf8.withContiguousStorageIfAvailable {
                hasher.combine(bytes: UnsafeRawBufferPointer($0))
            }
            if hashed == nil {
                Array(text.utf8).withUnsafeBytes { hasher.combine(bytes: $0) }
            }
            self.bytesHash = hasher.finalize()
        }

        static func == (lhs: UTF8Key, rhs: UTF8Key) -> Bool {
            lhs.bytesHash == rhs.bytesHash
                && lhs.text.utf8.count == rhs.text.utf8.count
                && lhs.text.utf8.elementsEqual(rhs.text.utf8)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(bytesHash)
        }
    }

    private struct Slot {
        var key: UTF8Key
        var value: [UInt32]
        var older: Int
        var newer: Int
    }

    private static let none = -1

    private let capacity: Int
    private var slotByKey: [UTF8Key: Int]
    private var slots: [Slot] = []
    private var freeSlots: [Int] = []
    /// Most recently used slot.
    private var newest = TokenizationCache.none
    /// Least recently used slot, evicted first.
    private var oldest = TokenizationCache.none

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.slotByKey = Dictionary(minimumCapacity: self.capacity + 1)
    }

    var count: Int { slotByKey.count }

    /// Cached tokens for `text`, marking it most recently used.
    func get(_ text: String) -> [UInt32]? {
        guard let slot = slotByKey[UTF8Key(text)] else { return nil }
        moveToNewest(slot)
        return slots[slot].value
    }

    /// Cached tokens for `text`, or `encode(text)` cached as most recently used.
    func tokens(for text: String, orEncode encode: (String) -> [UInt32]) -> [UInt32] {
        let key = UTF8Key(text)
        if let slot = slotByKey[key] {
            moveToNewest(slot)
            return slots[slot].value
        }
        let tokens = encode(text)
        insert(key, tokens)
        return tokens
    }

    /// Caches `tokens` for `text` as most recently used, evicting the least recently used
    /// entry when over capacity.
    func put(_ text: String, _ tokens: [UInt32]) {
        let key = UTF8Key(text)
        if let slot = slotByKey[key] {
            slots[slot].value = tokens
            moveToNewest(slot)
            return
        }
        insert(key, tokens)
    }

    /// Adds `key`, which must not be cached, as most recently used.
    private func insert(_ key: UTF8Key, _ tokens: [UInt32]) {
        let entry = Slot(key: key, value: tokens, older: newest, newer: Self.none)
        let slot: Int
        if let reused = freeSlots.popLast() {
            slots[reused] = entry
            slot = reused
        } else {
            slots.append(entry)
            slot = slots.count - 1
        }
        if newest != Self.none { slots[newest].newer = slot }
        newest = slot
        if oldest == Self.none { oldest = slot }
        slotByKey[key] = slot

        if slotByKey.count > capacity {
            evictOldest()
        }
    }

    func clear() {
        slotByKey.removeAll()
        slots.removeAll()
        freeSlots.removeAll()
        newest = Self.none
        oldest = Self.none
    }

    private func moveToNewest(_ slot: Int) {
        guard slot != newest else { return }
        unlink(slot)
        slots[slot].older = newest
        slots[slot].newer = Self.none
        if newest != Self.none { slots[newest].newer = slot }
        newest = slot
        if oldest == Self.none { oldest = slot }
    }

    private func evictOldest() {
        let slot = oldest
        guard slot != Self.none else { return }
        unlink(slot)
        slotByKey.removeValue(forKey: slots[slot].key)
        slots[slot].key = UTF8Key("")
        slots[slot].value = []
        freeSlots.append(slot)
    }

    private func unlink(_ slot: Int) {
        let older = slots[slot].older
        let newer = slots[slot].newer
        if older != Self.none { slots[older].newer = newer } else { oldest = newer }
        if newer != Self.none { slots[newer].older = older } else { newest = older }
    }
}

private actor TokenCounterCache {
    private var counters: [TokenCounter.Encoding: (counter: TokenCounter, cacheCapacity: Int)] = [:]

    func counter(for encoding: TokenCounter.Encoding, cacheCapacity: Int = 1024) async throws -> TokenCounter {
        if let cached = counters[encoding], cached.cacheCapacity == cacheCapacity {
            return cached.counter
        }
        let created = try await TokenCounter(encoding: encoding, cacheCapacity: cacheCapacity)
        counters[encoding] = (counter: created, cacheCapacity: cacheCapacity)
        return created
    }
}

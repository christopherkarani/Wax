import Foundation

/// Deterministic token counter backed by the built-in NativeBpeTokenizer.
/// Optimized with LRU caching to avoid redundant tokenization operations.
public actor TokenCounter {
    public enum Encoding: String, Sendable {
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
    public static let maxTokenizationBytes = 8 * 1024 * 1024

    private let tokenizer: NativeBpeTokenizer
    private let encodingCache: TokenizationCache

    public init(encoding: Encoding = .cl100kBase, cacheCapacity: Int = 1024) async throws {
        self.tokenizer = try await Self.nativeBpeCache.tokenizer(for: encoding)
        self.encodingCache = TokenizationCache(capacity: cacheCapacity)
    }

    public static func shared(encoding: Encoding = .cl100kBase, cacheCapacity: Int = 1024) async throws -> TokenCounter {
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
    public static func preload(encoding: Encoding = .cl100kBase) async throws -> Bool {
        _ = try await nativeBpeCache.tokenizer(for: encoding)
        return true
    }

    /// Check if the tokenizer is already loaded (no cold start penalty).
    public static func isPreloaded(encoding: Encoding = .cl100kBase) async -> Bool {
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

    public func count(_ text: String) -> Int {
        encode(text).count
    }

    public func truncate(_ text: String, maxTokens: Int) async -> String {
        guard maxTokens > 0 else { return "" }

        // Check cache for existing encoding
        if let cachedTokens = await encodingCache.get(text) {
            if cachedTokens.count <= maxTokens {
                return text
            }
            let sliced = Array(cachedTokens.prefix(maxTokens))
            return decode(sliced)
        }

        // Encode and cache
        let tokens = encode(text)
        await encodingCache.put(text, tokens)

        if tokens.count <= maxTokens {
            return text
        }
        let sliced = Array(tokens.prefix(maxTokens))
        return decode(sliced)
    }

    public func encode(_ text: String) -> [UInt32] {
        let capped = Self.cappedUTF8Prefix(text, maxBytes: Self.maxTokenizationBytes)
        return tokenizer.encode(capped)
    }

    public func decode(_ tokens: [UInt32]) -> String {
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
    public func countBatch(_ texts: [String]) async -> [Int] {
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
    public func encodeBatch(_ texts: [String]) async -> [[UInt32]] {
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
    public func truncateBatch(_ texts: [String], maxTokens: Int) async -> [String] {
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
    public func countAndTruncateBatch(_ texts: [String], maxTokens: Int) async -> [(count: Int, truncated: String)] {
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
/// Uses a doubly-linked list for O(1) access and eviction.
private actor TokenizationCache {
    private struct Entry {
        var key: String
        var value: [UInt32]
        var prev: String?
        var next: String?
    }

    private let capacity: Int
    private var entries: [String: Entry]
    private var head: String?
    private var tail: String?

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.entries = Dictionary(minimumCapacity: capacity)
    }

    /// Get cached tokens. O(1) time complexity.
    func get(_ text: String) -> [UInt32]? {
        guard var entry = entries[text] else { return nil }
        moveToFront(&entry)
        return entry.value
    }

    /// Cache tokens. Evicts LRU entry if at capacity. O(1) time complexity.
    func put(_ text: String, _ tokens: [UInt32]) {
        if var existing = entries[text] {
            existing.value = tokens
            moveToFront(&existing)
            return
        }

        let entry = Entry(key: text, value: tokens, prev: nil, next: head)
        if let headKey = head, var currentHead = entries[headKey] {
            currentHead.prev = text
            entries[headKey] = currentHead
        } else {
            tail = text
        }
        head = text
        entries[text] = entry

        if entries.count > capacity, let tailKey = tail {
            remove(tailKey)
        }
    }

    func clear() {
        entries.removeAll()
        head = nil
        tail = nil
    }

    private func moveToFront(_ entry: inout Entry) {
        let key = entry.key
        if head == key {
            entries[key] = entry
            return
        }

        let prevKey = entry.prev
        let nextKey = entry.next

        if let prevKey, var prev = entries[prevKey] {
            prev.next = nextKey
            entries[prevKey] = prev
        }
        if let nextKey, var next = entries[nextKey] {
            next.prev = prevKey
            entries[nextKey] = next
        }
        if tail == key {
            tail = prevKey
        }

        entry.prev = nil
        entry.next = head
        if let headKey = head, var currentHead = entries[headKey] {
            currentHead.prev = key
            entries[headKey] = currentHead
        }
        head = key
        entries[key] = entry
    }

    private func remove(_ key: String) {
        guard let entry = entries[key] else { return }
        let prevKey = entry.prev
        let nextKey = entry.next

        if let prevKey, var prev = entries[prevKey] {
            prev.next = nextKey
            entries[prevKey] = prev
        } else {
            head = nextKey
        }
        if let nextKey, var next = entries[nextKey] {
            next.prev = prevKey
            entries[nextKey] = next
        } else {
            tail = prevKey
        }
        entries.removeValue(forKey: key)
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

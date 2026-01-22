import Foundation
import TiktokenSwift

/// Deterministic token counter with a fixed encoding for all Phase 9 flows.
/// Optimized with LRU caching to avoid redundant tokenization operations.
public actor TokenCounter {
    public enum Encoding: String, Sendable {
        case cl100kBase = "cl100k_base"
    }

    struct BpeCacheStats: Sendable {
        var loadCount: Int = 0
    }

    private struct BPEBox: @unchecked Sendable {
        let value: CoreBpe
    }

    private actor CoreBpeCache {
        private var cache: [Encoding: BPEBox] = [:]
        private var stats = BpeCacheStats()

        func bpe(for encoding: Encoding) async throws -> BPEBox {
            if let cached = cache[encoding] { return cached }
            let loaded = try await CoreBpe.loadEncoding(named: encoding.rawValue)
            let boxed = BPEBox(value: loaded)
            cache[encoding] = boxed
            stats.loadCount += 1
            return boxed
        }

        func snapshotStats() -> BpeCacheStats { stats }

        func resetStats() {
            stats = BpeCacheStats()
        }
    }

    private static let sharedCache = TokenCounterCache()
    private static let bpeCache = CoreBpeCache()
    public static let maxTokenizationBytes = 8 * 1024 * 1024

    private let bpe: CoreBpe
    private let encodingCache: TokenizationCache

    public init(encoding: Encoding = .cl100kBase, cacheCapacity: Int = 1024) async throws {
        let bpeBox = try await Self.bpeCache.bpe(for: encoding)
        self.bpe = bpeBox.value
        self.encodingCache = TokenizationCache(capacity: cacheCapacity)
    }

    public static func shared(encoding: Encoding = .cl100kBase, cacheCapacity: Int = 1024) async throws -> TokenCounter {
        try await sharedCache.counter(for: encoding, cacheCapacity: cacheCapacity)
    }

    static func _bpeCacheStats() async -> BpeCacheStats {
        await bpeCache.snapshotStats()
    }

    static func _resetBpeCacheStats() async {
        await bpeCache.resetStats()
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
        let capped = cappedInput(text)
        return bpe.encode(text: capped, allowedSpecial: [])
    }

    public func decode(_ tokens: [UInt32]) -> String {
        (try? bpe.decode(tokens: tokens)) ?? ""
    }

    // MARK: - Batch Operations (Optimized)
    
    /// Thread-safe encoding using nonisolated access to the BPE model.
    /// CoreBpe is thread-safe for concurrent reads.
    nonisolated private func encodeNonisolated(_ text: String, bpe: CoreBpe) -> [UInt32] {
        let capped = Self.cappedUTF8Prefix(text, maxBytes: Self.maxTokenizationBytes)
        return bpe.encode(text: capped, allowedSpecial: [])
    }
    
    /// Thread-safe decoding using nonisolated access to the BPE model.
    nonisolated private func decodeNonisolated(_ tokens: [UInt32], bpe: CoreBpe) -> String {
        (try? bpe.decode(tokens: tokens)) ?? ""
    }

    /// Count tokens for multiple texts - uses parallel processing for better throughput.
    public func countBatch(_ texts: [String]) -> [Int] {
        // For small batches, sequential is faster due to overhead
        guard texts.count > 4 else {
            return texts.map { encode($0).count }
        }
        
        // Capture bpe for nonisolated parallel access
        let localBpe = bpe
        
        // Use unsafe mutable buffer for thread-safe parallel writes
        let results = UnsafeMutableBufferPointer<Int>.allocate(capacity: texts.count)
        defer { results.deallocate() }
        
        // Process in parallel using DispatchQueue for CPU-bound work
        DispatchQueue.concurrentPerform(iterations: texts.count) { index in
            results[index] = encodeNonisolated(texts[index], bpe: localBpe).count
        }
        
        return Array(results)
    }

    /// Encode multiple texts to tokens - uses parallel processing.
    public func encodeBatch(_ texts: [String]) -> [[UInt32]] {
        guard texts.count > 4 else {
            return texts.map { encode($0) }
        }
        
        let localBpe = bpe
        
        // Use array of optionals for thread-safe parallel writes
        var results = [[UInt32]?](repeating: nil, count: texts.count)
        
        DispatchQueue.concurrentPerform(iterations: texts.count) { index in
            let encoded = encodeNonisolated(texts[index], bpe: localBpe)
            results[index] = encoded
        }
        
        return results.compactMap { $0 }
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
        
        let localBpe = bpe
        
        // Batch encode all texts first (parallel)
        let allTokens = encodeBatch(texts)
        
        // Process truncation (parallel for decode operations)
        var results = [String?](repeating: nil, count: texts.count)
        
        DispatchQueue.concurrentPerform(iterations: texts.count) { index in
            let tokens = allTokens[index]
            if tokens.count <= maxTokens {
                results[index] = texts[index]
            } else {
                let sliced = Array(tokens.prefix(maxTokens))
                results[index] = decodeNonisolated(sliced, bpe: localBpe)
            }
        }
        
        return results.compactMap { $0 }
    }
    
    /// Optimized batch count and truncate - single pass for both operations.
    public func countAndTruncateBatch(_ texts: [String], maxTokens: Int) async -> [(count: Int, truncated: String)] {
        guard maxTokens > 0 else {
            return texts.map { _ in (count: 0, truncated: "") }
        }
        
        let localBpe = bpe
        
        // Batch encode all texts
        let allTokens = encodeBatch(texts)
        
        var results = [(count: Int, truncated: String)?](repeating: nil, count: texts.count)
        
        DispatchQueue.concurrentPerform(iterations: texts.count) { index in
            let tokens = allTokens[index]
            let count = tokens.count
            if count <= maxTokens {
                results[index] = (count: count, truncated: texts[index])
            } else {
                let sliced = Array(tokens.prefix(maxTokens))
                results[index] = (count: maxTokens, truncated: decodeNonisolated(sliced, bpe: localBpe))
            }
        }
        
        return results.compactMap { $0 }
    }

    private func cappedInput(_ text: String) -> String {
        Self.cappedUTF8Prefix(text, maxBytes: Self.maxTokenizationBytes)
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
private actor TokenizationCache {
    private let capacity: Int
    private var cache: [String: [UInt32]] = [:]
    private var accessOrder: [String] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func get(_ text: String) -> [UInt32]? {
        guard let tokens = cache[text] else { return nil }

        // Move to end of access order (most recently used)
        if let index = accessOrder.firstIndex(of: text) {
            accessOrder.remove(at: index)
        }
        accessOrder.append(text)

        return tokens
    }

    func put(_ text: String, _ tokens: [UInt32]) {
        // Remove existing entry if present
        if let index = accessOrder.firstIndex(of: text) {
            accessOrder.remove(at: index)
        }

        // Evict least recently used if at capacity
        if cache.count >= capacity && !cache.keys.contains(text) {
            if let lru = accessOrder.first {
                cache.removeValue(forKey: lru)
                accessOrder.removeFirst()
            }
        }

        // Add new entry
        cache[text] = tokens
        accessOrder.append(text)
    }

    func clear() {
        cache.removeAll()
        accessOrder.removeAll()
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

import Foundation
import WaxCore
import WaxVectorSearch

extension MemoryOrchestrator {
    // MARK: - Math helpers

    /// L2 normalization using Accelerate framework for optimal SIMD performance.
    /// Internal only because of the file split.
    @inline(__always)
    static func normalizedL2(_ vector: [Float]) -> [Float] {
        VectorMath.normalizeL2(vector)
    }

    private static func writeEmbeddings(_ embeddings: [[Float]], to url: URL) throws {
        var data = Data()
        data.reserveCapacity(8 + embeddings.reduce(0) { $0 + ($1.count * 4) })

        var count = UInt32(embeddings.count).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }

        for vector in embeddings {
            guard vector.count <= Int(UInt32.max) else {
                throw WaxError.encodingError(reason: "embedding dimension exceeds UInt32.max")
            }
            var dimension = UInt32(vector.count).littleEndian
            withUnsafeBytes(of: &dimension) { data.append(contentsOf: $0) }
            for value in vector {
                var bits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
        }

        try data.write(to: url, options: .atomic)
    }

    private static func readEmbeddings(from url: URL) throws -> [[Float]] {
        let data = try Data(contentsOf: url)
        var offset = 0

        func readUInt32() throws -> UInt32 {
            guard data.count - offset >= 4 else {
                throw WaxError.decodingError(reason: "invalid embedding batch payload")
            }
            var raw: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &raw) { destination in
                data.copyBytes(to: destination, from: offset..<(offset + 4))
            }
            let value = UInt32(littleEndian: raw)
            offset += 4
            return value
        }

        let count = try Int(readUInt32())
        var embeddings: [[Float]] = []
        embeddings.reserveCapacity(count)

        for _ in 0..<count {
            let dimension = try Int(readUInt32())
            guard dimension >= 0 else {
                throw WaxError.decodingError(reason: "invalid embedding dimension")
            }
            guard data.count - offset >= dimension * 4 else {
                throw WaxError.decodingError(reason: "invalid embedding batch payload")
            }
            var vector: [Float] = []
            vector.reserveCapacity(dimension)
            for _ in 0..<dimension {
                var raw: UInt32 = 0
                _ = withUnsafeMutableBytes(of: &raw) { destination in
                    data.copyBytes(to: destination, from: offset..<(offset + 4))
                }
                let bits = UInt32(littleEndian: raw)
                vector.append(Float(bitPattern: bits))
                offset += 4
            }
            embeddings.append(vector)
        }

        guard offset == data.count else {
            throw WaxError.decodingError(reason: "invalid embedding batch payload trailing bytes")
        }

        return embeddings
    }

    #if DEBUG
    private final class DebugCounterState: @unchecked Sendable {
        let lock = NSLock()
        var batchPreparationPathCallCounts: [String: Int] = [:]
        var memoryBindingEnsureCallCounts: [String: Int] = [:]
    }

    private static let debugCounterState = DebugCounterState()
    @TaskLocal private static var activeDebugCounterScopeKey: String?

    package static func _recordBatchPreparationPathCallForTests() {
        debugCounterState.lock.lock()
        let key = activeDebugCounterScopeKey ?? "__global__"
        debugCounterState.batchPreparationPathCallCounts[key, default: 0] += 1
        debugCounterState.lock.unlock()
    }

    package static func _withIsolatedDebugCountersForTests<T: Sendable>(
        _ body: @Sendable (String) async throws -> T
    ) async rethrows -> T {
        let key = UUID().uuidString
        return try await $activeDebugCounterScopeKey.withValue(key) {
            try await body(key)
        }
    }

    package static func _resetBatchPreparationPathCallCountForTests(scopeKey: String? = nil) {
        debugCounterState.lock.lock()
        let key = scopeKey ?? activeDebugCounterScopeKey ?? "__global__"
        debugCounterState.batchPreparationPathCallCounts[key] = 0
        debugCounterState.lock.unlock()
    }

    package static func _batchPreparationPathCallCountForTests(scopeKey: String? = nil) -> Int {
        debugCounterState.lock.lock()
        let key = scopeKey ?? activeDebugCounterScopeKey ?? "__global__"
        let count = debugCounterState.batchPreparationPathCallCounts[key, default: 0]
        debugCounterState.lock.unlock()
        return count
    }

    package static func _recordMemoryBindingEnsureCallForTests() {
        debugCounterState.lock.lock()
        let key = activeDebugCounterScopeKey ?? "__global__"
        debugCounterState.memoryBindingEnsureCallCounts[key, default: 0] += 1
        debugCounterState.lock.unlock()
    }

    package static func _resetMemoryBindingEnsureCallCountForTests(scopeKey: String? = nil) {
        debugCounterState.lock.lock()
        let key = scopeKey ?? activeDebugCounterScopeKey ?? "__global__"
        debugCounterState.memoryBindingEnsureCallCounts[key] = 0
        debugCounterState.lock.unlock()
    }

    package static func _memoryBindingEnsureCallCountForTests(scopeKey: String? = nil) -> Int {
        debugCounterState.lock.lock()
        let key = scopeKey ?? activeDebugCounterScopeKey ?? "__global__"
        let count = debugCounterState.memoryBindingEnsureCallCounts[key, default: 0]
        debugCounterState.lock.unlock()
        return count
    }

    package static func _writeEmbeddingsForTesting(_ embeddings: [[Float]], to url: URL) throws {
        try writeEmbeddings(embeddings, to: url)
    }

    package static func _readEmbeddingsForTesting(from url: URL) throws -> [[Float]] {
        try readEmbeddings(from: url)
    }
    #endif

    /// Rejects a vector the store could never index: the vector engines refuse it on add, and
    /// once it is in the WAL every flush and every later open would fail on it.
    /// Internal only because of the file split.
    static func validateIngestVector(_ vector: [Float], from embedder: any EmbeddingProvider) throws {
        guard vector.count == embedder.dimensions else {
            throw WaxError.invalidEmbedding(
                reason: "embedding provider \(providerName(embedder)) returned \(vector.count) dimensions; it declares \(embedder.dimensions)"
            )
        }
        guard vector.allSatisfy(\.isFinite) else {
            throw WaxError.invalidEmbedding(
                reason: "embedding provider \(providerName(embedder)) returned a non-finite value (NaN or infinity)"
            )
        }
    }

    private static func providerName(_ embedder: any EmbeddingProvider) -> String {
        guard let identity = embedder.identity else { return String(describing: type(of: embedder)) }
        return "\(identity.provider ?? "unknown")/\(identity.model ?? "unknown")"
    }

    /// Internal only because of the file split.
    static func embedOne(
        _ text: String,
        attached: any EmbeddingProvider,
        cache: EmbeddingMemoizer?,
        timeout: Duration? = nil,
        isQuery: Bool = false
    ) async throws -> [Float] {
        let embedder = attached
        let key = EmbeddingKey.make(
            text: text,
            identity: embedder.identity,
            dimensions: embedder.dimensions,
            normalized: embedder.normalize,
            queryAware: isQuery
        )
        if let cached = await cache?.get(key) {
            return cached
        }

        let produce: @Sendable () async throws -> [Float] = {
            if isQuery {
                return try await embedder.embedQuery(text)
            }
            let vectors = try await embedder.embed(batch: [text])
            guard vectors.count == 1, let vector = vectors.first else {
                throw WaxError.encodingError(
                    reason: "batch embedding returned \(vectors.count) vectors for 1 inputs"
                )
            }
            return vector
        }

        var vector: [Float]
        if let timeout {
            vector = try await AsyncTimeout.run(
                timeout: timeout,
                operation: isQuery ? "embedder.embedQuery" : "batch ingest embed"
            ) {
                try await produce()
            }
        } else {
            vector = try await produce()
        }
        if !isQuery {
            try validateIngestVector(vector, from: embedder)
        }
        if embedder.normalize {
            vector = normalizedL2(vector)
        }
        await cache?.set(key, value: vector)
        return vector
    }

    private static func prepareEmbeddings(
        chunks: [String],
        attached: any EmbeddingProvider,
        cache: EmbeddingMemoizer?
    ) async throws -> [Int: [Float]] {
        let embedder = attached
        var out: [Int: [Float]] = [:]
        out.reserveCapacity(chunks.count)

        var missingTexts: [String] = []
        var missingIndices: [Int] = []
        missingTexts.reserveCapacity(chunks.count)
        missingIndices.reserveCapacity(chunks.count)

        for (idx, chunk) in chunks.enumerated() {
            let key = EmbeddingKey.make(
                text: chunk,
                identity: embedder.identity,
                dimensions: embedder.dimensions,
                normalized: embedder.normalize
            )
            if let cached = await cache?.get(key) {
                out[idx] = cached
            } else {
                missingTexts.append(chunk)
                missingIndices.append(idx)
            }
        }

        if missingTexts.isEmpty {
            return out
        }

        let vectors = try await embedder.embed(batch: missingTexts)
        guard vectors.count == missingTexts.count else {
            throw WaxError.io("batch embedding count mismatch: expected \(missingTexts.count), got \(vectors.count)")
        }
        for (position, idx) in missingIndices.enumerated() {
            var vector = vectors[position]
            if embedder.normalize {
                vector = normalizedL2(vector)
            }
            out[idx] = vector
            let key = EmbeddingKey.make(
                text: chunks[idx],
                identity: embedder.identity,
                dimensions: embedder.dimensions,
                normalized: embedder.normalize
            )
            await cache?.set(key, value: vector)
        }

        return out
    }
}

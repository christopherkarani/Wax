import Foundation
import SimilaritySearchKit
import SimilaritySearchKitMiniLMAll
import WaxCore
import WaxVectorSearch

extension MiniLMEmbeddings: @retroactive @unchecked Sendable {}

/// High-performance MiniLM embedder with batch support for optimal ANE/GPU utilization.
/// Implements BatchEmbeddingProvider for significant throughput improvements during ingest.
public actor MiniLMEmbedder: EmbeddingProvider, BatchEmbeddingProvider {
    public nonisolated let dimensions: Int = 384
    public nonisolated let normalize: Bool = true
    public nonisolated let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "SimilaritySearchKit",
        model: "MiniLMAll",
        dimensions: 384,
        normalized: true
    )

    private let model: MiniLMEmbeddings
    
    /// Optimal batch size for ANE throughput - balances memory usage with parallelism
    private static let optimalBatchSize = 16
    
    /// Concurrent encoding limit to maximize throughput while avoiding resource contention
    private static let maxConcurrentEncodings = 8

    public init() {
        self.model = MiniLMEmbeddings()
    }

    public init(model: MiniLMEmbeddings) {
        self.model = model
    }

    public func embed(_ text: String) async throws -> [Float] {
        guard let vector = await model.encode(sentence: text) else {
            throw WaxError.io("MiniLMAll embedding failed to produce a vector.")
        }
        if vector.count != dimensions {
            throw WaxError.io("MiniLMAll produced \(vector.count) dims, expected \(dimensions).")
        }
        return vector
    }
    
    /// Batch embed multiple texts with optimized concurrent processing.
    /// Uses structured concurrency with controlled parallelism for optimal ANE/GPU utilization.
    ///
    /// Performance characteristics:
    /// - Sub-batches of 16 texts processed concurrently (optimal for CoreML)
    /// - Up to 8 concurrent sub-batches to saturate compute resources
    /// - Returns embeddings in same order as input texts
    public func embed(batch texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        
        // For small batches, process directly with controlled concurrency
        if texts.count <= Self.optimalBatchSize {
            return try await embedConcurrent(texts: texts)
        }
        
        // For larger batches, chunk into optimal sub-batches and process in parallel
        let chunks = texts.chunked(into: Self.optimalBatchSize)
        
        // Process chunks with bounded concurrency using TaskGroup
        return try await withThrowingTaskGroup(of: (Int, [[Float]]).self) { group in
            var results = Array(repeating: [[Float]](), count: chunks.count)
            var activeCount = 0
            var chunkIndex = 0
            
            // Add initial batch of tasks up to max concurrent limit
            while chunkIndex < chunks.count && activeCount < Self.maxConcurrentEncodings {
                let idx = chunkIndex
                let chunk = chunks[idx]
                group.addTask {
                    let embeddings = try await self.embedConcurrent(texts: chunk)
                    return (idx, embeddings)
                }
                activeCount += 1
                chunkIndex += 1
            }
            
            // Process results and add new tasks as slots become available
            for try await (idx, embeddings) in group {
                results[idx] = embeddings
                activeCount -= 1
                
                // Add next chunk if available
                if chunkIndex < chunks.count {
                    let nextIdx = chunkIndex
                    let nextChunk = chunks[nextIdx]
                    group.addTask {
                        let embeddings = try await self.embedConcurrent(texts: nextChunk)
                        return (nextIdx, embeddings)
                    }
                    activeCount += 1
                    chunkIndex += 1
                }
            }
            
            return results.flatMap { $0 }
        }
    }
    
    /// Concurrently embed a small batch of texts with controlled parallelism.
    private func embedConcurrent(texts: [String]) async throws -> [[Float]] {
        // Use TaskGroup for concurrent embedding with automatic load balancing
        try await withThrowingTaskGroup(of: (Int, [Float]).self) { group in
            for (index, text) in texts.enumerated() {
                group.addTask {
                    guard let vector = await self.model.encode(sentence: text) else {
                        throw WaxError.io("MiniLMAll embedding failed for text at index \(index)")
                    }
                    return (index, vector)
                }
            }
            
            var results = Array(repeating: [Float](), count: texts.count)
            for try await (index, vector) in group {
                if vector.count != self.dimensions {
                    throw WaxError.io("MiniLMAll produced \(vector.count) dims, expected \(self.dimensions).")
                }
                results[index] = vector
            }
            return results
        }
    }
}

// MARK: - Array Chunking Extension

private extension Array {
    /// Splits the array into chunks of the specified size.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

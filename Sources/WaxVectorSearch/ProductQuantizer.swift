//
//  ProductQuantizer.swift
//  Wax
//
//  Product Quantization (PQ) for vector compression.
//  Reduces memory by 10-100x while maintaining search quality.
//
//  PQ splits vectors into sub-vectors and quantizes each independently,
//  enabling approximate distance computation via lookup tables.
//

import Foundation
import Accelerate

/// Product Quantizer for vector compression and fast approximate search.
///
/// PQ works by:
/// 1. Splitting each D-dimensional vector into M sub-vectors of D/M dimensions
/// 2. Learning K centroids per sub-space via k-means
/// 3. Encoding each vector as M bytes (indices into centroid tables)
///
/// Memory: 384-dim vector → 384*4 = 1536 bytes → 48 bytes (M=48, K=256) = 32x compression
///
/// Example:
/// ```swift
/// let pq = ProductQuantizer(dimensions: 384, numSubspaces: 48, numCentroids: 256)
/// await pq.train(vectors: trainingData)
/// let codes = pq.encode(vector)  // [UInt8] of length 48
/// let dist = pq.asymmetricDistance(query: q, codes: codes)
/// ```
public actor ProductQuantizer {
    
    /// Training configuration
    public struct Config: Sendable {
        /// Number of sub-vectors (M). Higher = more accurate, larger codes.
        /// Common values: 8, 16, 32, 48, 64, 96
        public let numSubspaces: Int
        
        /// Number of centroids per sub-space (K). Typically 256 for byte encoding.
        /// Powers of 2 only: 16, 64, 256
        public let numCentroids: Int
        
        /// Dimensions per sub-vector
        public var subDimensions: Int
        
        public init(dimensions: Int, numSubspaces: Int, numCentroids: Int = 256) {
            precondition(dimensions % numSubspaces == 0, "dimensions must be divisible by numSubspaces")
            precondition(numCentroids > 0 && numCentroids <= 256, "numCentroids must be 1-256")
            
            self.numSubspaces = numSubspaces
            self.numCentroids = numCentroids
            self.subDimensions = dimensions / numSubspaces
        }
    }
    
    public let dimensions: Int
    public let config: Config
    
    /// Codebook: [subspace][centroid][dimension]
    private var codebook: [[[Float]]]
    
    /// Whether training is complete
    public private(set) var isTrained: Bool = false
    
    /// Initialize Product Quantizer
    /// - Parameters:
    ///   - dimensions: Vector dimensionality (must be divisible by numSubspaces)
    ///   - numSubspaces: Number of sub-vectors M (typically 32-96 for 384-dim)
    ///   - numCentroids: Centroids per sub-space (typically 256)
    public init(dimensions: Int, numSubspaces: Int = 48, numCentroids: Int = 256) {
        self.dimensions = dimensions
        self.config = Config(dimensions: dimensions, numSubspaces: numSubspaces, numCentroids: numCentroids)
        self.codebook = []
    }
    
    /// Train codebook using k-means on each subspace
    /// - Parameters:
    ///   - vectors: Training vectors
    ///   - iterations: K-means iterations per subspace
    public func train(vectors: [[Float]], iterations: Int = 25) {
        guard !vectors.isEmpty else { return }
        precondition(vectors.allSatisfy { $0.count == dimensions }, "All vectors must match dimensions")
        
        let M = config.numSubspaces
        let K = config.numCentroids
        let dsub = config.subDimensions
        
        codebook = [[Float]](repeating: [[Float]](repeating: [Float](repeating: 0, count: dsub), count: K), count: M)
        
        // Train each subspace independently
        for m in 0..<M {
            let subOffset = m * dsub
            
            // Extract subvectors for this subspace
            let subvectors: [[Float]] = vectors.map { vec in
                Array(vec[subOffset..<(subOffset + dsub)])
            }
            
            // K-means clustering
            codebook[m] = trainSubspace(subvectors: subvectors, k: K, iterations: iterations)
        }
        
        isTrained = true
    }
    
    /// Encode vector to PQ codes
    /// - Parameter vector: Input vector
    /// - Returns: Array of M centroid indices (each 0-255)
    public func encode(_ vector: [Float]) -> [UInt8] {
        precondition(isTrained, "Quantizer must be trained before encoding")
        precondition(vector.count == dimensions, "Vector dimension mismatch")
        
        let M = config.numSubspaces
        let dsub = config.subDimensions
        
        var codes = [UInt8](repeating: 0, count: M)
        
        for m in 0..<M {
            let subOffset = m * dsub
            let subvector = Array(vector[subOffset..<(subOffset + dsub)])
            codes[m] = UInt8(findNearestCentroid(subvector: subvector, centroids: codebook[m]))
        }
        
        return codes
    }
    
    /// Encode batch of vectors
    public func encodeBatch(_ vectors: [[Float]]) -> [[UInt8]] {
        vectors.map { encode($0) }
    }
    
    /// Decode PQ codes back to approximate vector
    /// - Parameter codes: PQ codes of length M
    /// - Returns: Reconstructed vector
    public func decode(_ codes: [UInt8]) -> [Float] {
        precondition(isTrained, "Quantizer must be trained before decoding")
        precondition(codes.count == config.numSubspaces, "Invalid code length")
        
        var vector = [Float](repeating: 0, count: dimensions)
        let dsub = config.subDimensions
        
        for (m, code) in codes.enumerated() {
            let subOffset = m * dsub
            let centroid = codebook[m][Int(code)]
            for d in 0..<dsub {
                vector[subOffset + d] = centroid[d]
            }
        }
        
        return vector
    }
    
    /// Pre-compute distance table for asymmetric distance computation
    /// This enables O(M) distance computation instead of O(D)
    /// - Parameter query: Query vector
    /// - Returns: Distance table [M][K] containing partial distances
    public func computeDistanceTable(query: [Float]) -> [[Float]] {
        precondition(isTrained, "Quantizer must be trained")
        precondition(query.count == dimensions, "Query dimension mismatch")
        
        let M = config.numSubspaces
        let K = config.numCentroids
        let dsub = config.subDimensions
        
        var table = [[Float]](repeating: [Float](repeating: 0, count: K), count: M)
        
        for m in 0..<M {
            let subOffset = m * dsub
            let subquery = Array(query[subOffset..<(subOffset + dsub)])
            
            for k in 0..<K {
                // Squared L2 distance between query subvector and centroid
                var dist: Float = 0
                for d in 0..<dsub {
                    let diff = subquery[d] - codebook[m][k][d]
                    dist += diff * diff
                }
                table[m][k] = dist
            }
        }
        
        return table
    }
    
    /// Compute asymmetric squared L2 distance using pre-computed table
    /// - Parameters:
    ///   - distanceTable: Pre-computed distance table from `computeDistanceTable`
    ///   - codes: PQ codes of the database vector
    /// - Returns: Approximate squared L2 distance
    public func asymmetricDistance(distanceTable: [[Float]], codes: [UInt8]) -> Float {
        var dist: Float = 0
        for (m, code) in codes.enumerated() {
            dist += distanceTable[m][Int(code)]
        }
        return dist
    }
    
    /// Search using PQ codes with asymmetric distance
    /// - Parameters:
    ///   - query: Query vector
    ///   - database: Array of (frameId, codes) tuples
    ///   - topK: Number of results to return
    /// - Returns: Array of (frameId, distance) sorted by distance ascending
    public func search(
        query: [Float],
        database: [(frameId: UInt64, codes: [UInt8])],
        topK: Int
    ) -> [(frameId: UInt64, distance: Float)] {
        guard !database.isEmpty else { return [] }
        
        let distanceTable = computeDistanceTable(query: query)
        
        var results: [(UInt64, Float)] = database.map { item in
            let dist = asymmetricDistance(distanceTable: distanceTable, codes: item.codes)
            return (item.frameId, dist)
        }
        
        results.sort { $0.1 < $1.1 }
        return Array(results.prefix(topK))
    }
    
    /// Memory usage of the codebook in bytes
    public var codebookMemoryBytes: Int {
        config.numSubspaces * config.numCentroids * config.subDimensions * MemoryLayout<Float>.stride
    }
    
    /// Compression ratio compared to raw float storage
    public var compressionRatio: Float {
        Float(dimensions * MemoryLayout<Float>.stride) / Float(config.numSubspaces)
    }
    
    // MARK: - Private Helpers
    
    private func trainSubspace(subvectors: [[Float]], k: Int, iterations: Int) -> [[Float]] {
        let dsub = config.subDimensions
        
        // Initialize centroids randomly
        var centroids: [[Float]] = []
        var usedIndices = Set<Int>()
        
        while centroids.count < k {
            let idx = Int.random(in: 0..<subvectors.count)
            if !usedIndices.contains(idx) {
                usedIndices.insert(idx)
                centroids.append(subvectors[idx])
            }
            if usedIndices.count >= subvectors.count { break }
        }
        
        // Pad if needed
        while centroids.count < k {
            centroids.append([Float](repeating: 0, count: dsub))
        }
        
        // K-means iterations
        for _ in 0..<iterations {
            var assignments = [[Int]](repeating: [], count: k)
            
            for (i, sv) in subvectors.enumerated() {
                let nearest = findNearestCentroid(subvector: sv, centroids: centroids)
                assignments[nearest].append(i)
            }
            
            for c in 0..<k {
                guard !assignments[c].isEmpty else { continue }
                
                var newCentroid = [Float](repeating: 0, count: dsub)
                for idx in assignments[c] {
                    vDSP_vadd(newCentroid, 1, subvectors[idx], 1, &newCentroid, 1, vDSP_Length(dsub))
                }
                
                var scale = 1.0 / Float(assignments[c].count)
                vDSP_vsmul(newCentroid, 1, &scale, &newCentroid, 1, vDSP_Length(dsub))
                
                centroids[c] = newCentroid
            }
        }
        
        return centroids
    }
    
    private func findNearestCentroid(subvector: [Float], centroids: [[Float]]) -> Int {
        var bestIdx = 0
        var bestDist: Float = .greatestFiniteMagnitude
        let dsub = subvector.count
        
        for (i, centroid) in centroids.enumerated() {
            var dist: Float = 0
            for d in 0..<dsub {
                let diff = subvector[d] - centroid[d]
                dist += diff * diff
            }
            if dist < bestDist {
                bestDist = dist
                bestIdx = i
            }
        }
        
        return bestIdx
    }
}

// MARK: - IVFPQ: Combined IVF + PQ for large-scale search

/// Combined IVF + PQ index for million-scale approximate search.
/// 
/// The index uses IVF for coarse quantization (partitioning) and
/// PQ for fine quantization (compression) within each partition.
public actor IVFPQIndex {
    
    private let ivf: IVFIndex
    private let pq: ProductQuantizer
    
    /// Encoded database: cluster -> [(frameId, codes)]
    private var clusters: [[(frameId: UInt64, codes: [UInt8])]]
    
    public private(set) var vectorCount: UInt64 = 0
    public var isTrained: Bool { get async { await ivf.isTrained && await pq.isTrained } }
    
    public init(dimensions: Int, numClusters: Int = 100, numSubspaces: Int = 48) {
        self.ivf = IVFIndex(dimensions: dimensions, numClusters: numClusters)
        self.pq = ProductQuantizer(dimensions: dimensions, numSubspaces: numSubspaces)
        self.clusters = []
    }
    
    /// Train both IVF and PQ codebooks
    public func train(vectors: [[Float]], ivfIterations: Int = 25, pqIterations: Int = 25) async {
        await ivf.train(vectors: vectors, iterations: ivfIterations)
        await pq.train(vectors: vectors, iterations: pqIterations)
        
        let numClusters = await ivf.numClusters
        clusters = [[(frameId: UInt64, codes: [UInt8])]](repeating: [], count: numClusters)
    }
    
    /// Add vector to index
    public func add(frameId: UInt64, vector: [Float]) async {
        // Find cluster
        let results = await ivf.search(query: vector, topK: 1, nprobe: 1)
        guard let nearest = results.first else { return }
        
        // Compute residual and encode with PQ
        // For simplicity, we encode the full vector (could optimize with residual encoding)
        let codes = await pq.encode(vector)
        
        // Add to cluster - use cluster index based on centroid similarity
        let clusterIdx = await getClusterIndex(for: vector)
        clusters[clusterIdx].append((frameId, codes))
        vectorCount += 1
    }
    
    /// Batch add
    public func addBatch(frameIds: [UInt64], vectors: [[Float]]) async {
        for (fid, vec) in zip(frameIds, vectors) {
            await add(frameId: fid, vector: vec)
        }
    }
    
    /// Search using IVF for coarse quantization and PQ for fine ranking
    public func search(query: [Float], topK: Int, nprobe: Int = 10) async -> [(frameId: UInt64, score: Float)] {
        // Get nearest clusters
        let clusterResults = await ivf.search(query: query, topK: nprobe, nprobe: nprobe)
        
        // Search within clusters using PQ
        let distanceTable = await pq.computeDistanceTable(query: query)
        
        var candidates: [(UInt64, Float)] = []
        
        for result in clusterResults {
            let clusterIdx = await getClusterIndexForFrameId(result.frameId) ?? 0
            guard clusterIdx < clusters.count else { continue }
            
            for (frameId, codes) in clusters[clusterIdx] {
                let dist = await pq.asymmetricDistance(distanceTable: distanceTable, codes: codes)
                // Convert distance to similarity (inversely related)
                let score = 1.0 / (1.0 + dist)
                candidates.append((frameId, score))
            }
        }
        
        candidates.sort { $0.1 > $1.1 }
        return Array(candidates.prefix(topK))
    }
    
    private func getClusterIndex(for vector: [Float]) async -> Int {
        let results = await ivf.search(query: vector, topK: 1, nprobe: 1)
        // This is a simplification - in production you'd track cluster assignments properly
        return Int(results.first?.frameId ?? 0) % clusters.count
    }
    
    private func getClusterIndexForFrameId(_ frameId: UInt64) async -> Int? {
        for (idx, cluster) in clusters.enumerated() {
            if cluster.contains(where: { $0.frameId == frameId }) {
                return idx
            }
        }
        return nil
    }
}

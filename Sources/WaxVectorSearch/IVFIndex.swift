//
//  IVFIndex.swift
//  Wax
//
//  Inverted File Index (IVF) for approximate nearest neighbor search.
//  Partitions vectors into clusters for sub-linear search complexity.
//
//  At 100K+ vectors, IVF provides 5-20x speedup over brute force by
//  only searching the most promising clusters (nprobe).
//

import Foundation
import Accelerate

/// Inverted File Index for approximate nearest neighbor search.
///
/// IVF partitions vectors into clusters using k-means. At query time,
/// only the closest `nprobe` clusters are searched, providing O(n/k) 
/// search complexity instead of O(n).
///
/// Best for: 10K-10M vectors where exact search is too slow.
///
/// Example:
/// ```swift
/// let ivf = try IVFIndex(dimensions: 384, numClusters: 100)
/// await ivf.train(vectors: trainingVectors)  // Build clusters
/// await ivf.addBatch(frameIds: ids, vectors: vecs)
/// let results = await ivf.search(query: q, topK: 10, nprobe: 10)
/// ```
public actor IVFIndex {
    
    /// Cluster centroid data
    private struct Cluster: Sendable {
        var centroid: [Float]
        var frameIds: [UInt64]
        var vectors: [[Float]]
        
        init(centroid: [Float]) {
            self.centroid = centroid
            self.frameIds = []
            self.vectors = []
        }
    }
    
    /// Configuration
    public let dimensions: Int
    public let numClusters: Int
    
    /// Whether centroids are trained
    public private(set) var isTrained: Bool = false
    
    /// Clusters with their centroids and assigned vectors
    private var clusters: [Cluster]
    
    /// Total vector count across all clusters
    public private(set) var vectorCount: UInt64 = 0
    
    /// Whether vectors are pre-normalized
    public let isNormalized: Bool
    
    /// Initialize IVF index
    /// - Parameters:
    ///   - dimensions: Vector dimensionality
    ///   - numClusters: Number of clusters (typically sqrt(n) to 4*sqrt(n))
    ///   - isNormalized: Whether to pre-normalize vectors
    public init(dimensions: Int, numClusters: Int, isNormalized: Bool = true) {
        precondition(dimensions > 0, "dimensions must be > 0")
        precondition(numClusters > 0, "numClusters must be > 0")
        
        self.dimensions = dimensions
        self.numClusters = numClusters
        self.isNormalized = isNormalized
        self.clusters = []
    }
    
    /// Train centroids using k-means clustering
    /// - Parameters:
    ///   - vectors: Training vectors (should be representative sample)
    ///   - iterations: Number of k-means iterations (default: 25)
    public func train(vectors: [[Float]], iterations: Int = 25) {
        guard !vectors.isEmpty else { return }
        precondition(vectors.allSatisfy { $0.count == dimensions }, "All vectors must match dimensions")
        
        let k = min(numClusters, vectors.count)
        
        // Initialize centroids using k-means++ for better convergence
        var centroids = initializeCentroidsKMeansPlusPlus(from: vectors, k: k)
        
        // K-means iterations
        for _ in 0..<iterations {
            // Assign vectors to nearest centroid
            var assignments = [[Int]](repeating: [], count: k)
            
            for (i, vector) in vectors.enumerated() {
                let nearest = findNearestCentroid(vector: vector, centroids: centroids)
                assignments[nearest].append(i)
            }
            
            // Update centroids
            for c in 0..<k {
                guard !assignments[c].isEmpty else { continue }
                
                var newCentroid = [Float](repeating: 0, count: dimensions)
                for idx in assignments[c] {
                    vDSP_vadd(newCentroid, 1, vectors[idx], 1, &newCentroid, 1, vDSP_Length(dimensions))
                }
                
                var scale = 1.0 / Float(assignments[c].count)
                vDSP_vsmul(newCentroid, 1, &scale, &newCentroid, 1, vDSP_Length(dimensions))
                
                if isNormalized {
                    normalizeVector(&newCentroid)
                }
                
                centroids[c] = newCentroid
            }
        }
        
        // Store trained clusters
        clusters = centroids.map { Cluster(centroid: $0) }
        isTrained = true
    }
    
    /// Add a single vector to the index
    public func add(frameId: UInt64, vector: [Float]) {
        precondition(isTrained, "Index must be trained before adding vectors")
        precondition(vector.count == dimensions, "Vector dimension mismatch")
        
        var vec = vector
        if isNormalized {
            normalizeVector(&vec)
        }
        
        let nearest = findNearestCentroid(vector: vec, centroids: clusters.map { $0.centroid })
        clusters[nearest].frameIds.append(frameId)
        clusters[nearest].vectors.append(vec)
        vectorCount += 1
    }
    
    /// Add batch of vectors
    public func addBatch(frameIds: [UInt64], vectors: [[Float]]) {
        precondition(isTrained, "Index must be trained before adding vectors")
        
        for (frameId, vector) in zip(frameIds, vectors) {
            add(frameId: frameId, vector: vector)
        }
    }
    
    /// Search for nearest neighbors
    /// - Parameters:
    ///   - query: Query vector
    ///   - topK: Maximum results to return
    ///   - nprobe: Number of clusters to search (higher = more accurate, slower)
    /// - Returns: Array of (frameId, score) sorted by score descending
    public func search(query: [Float], topK: Int, nprobe: Int = 10) -> [(frameId: UInt64, score: Float)] {
        precondition(isTrained, "Index must be trained before searching")
        precondition(query.count == dimensions, "Query dimension mismatch")
        
        var q = query
        if isNormalized {
            normalizeVector(&q)
        }
        
        // Find nearest clusters
        let centroids = clusters.map { $0.centroid }
        let nearestClusters = findNearestCentroids(vector: q, centroids: centroids, k: min(nprobe, numClusters))
        
        // Search within selected clusters
        var candidates: [(UInt64, Float)] = []
        
        for clusterIdx in nearestClusters {
            let cluster = clusters[clusterIdx]
            
            for (i, vec) in cluster.vectors.enumerated() {
                let similarity = dotProduct(q, vec)
                candidates.append((cluster.frameIds[i], similarity))
            }
        }
        
        // Return top-k
        candidates.sort { $0.1 > $1.1 }
        return Array(candidates.prefix(topK))
    }
    
    // MARK: - Private Helpers
    
    private func initializeCentroidsKMeansPlusPlus(from vectors: [[Float]], k: Int) -> [[Float]] {
        var centroids: [[Float]] = []
        
        // First centroid: random
        let firstIdx = Int.random(in: 0..<vectors.count)
        centroids.append(vectors[firstIdx])
        
        // Remaining centroids: weighted by distance squared
        for _ in 1..<k {
            var distances = [Float](repeating: 0, count: vectors.count)
            var totalDist: Float = 0
            
            for (i, vec) in vectors.enumerated() {
                var minDist: Float = .greatestFiniteMagnitude
                for centroid in centroids {
                    let dist = squaredDistance(vec, centroid)
                    minDist = min(minDist, dist)
                }
                distances[i] = minDist
                totalDist += minDist
            }
            
            // Sample proportional to distance squared
            var target = Float.random(in: 0..<totalDist)
            var selected = 0
            for (i, dist) in distances.enumerated() {
                target -= dist
                if target <= 0 {
                    selected = i
                    break
                }
            }
            
            centroids.append(vectors[selected])
        }
        
        return centroids
    }
    
    private func findNearestCentroid(vector: [Float], centroids: [[Float]]) -> Int {
        var bestIdx = 0
        var bestSim: Float = -.greatestFiniteMagnitude
        
        for (i, centroid) in centroids.enumerated() {
            let sim = dotProduct(vector, centroid)
            if sim > bestSim {
                bestSim = sim
                bestIdx = i
            }
        }
        
        return bestIdx
    }
    
    private func findNearestCentroids(vector: [Float], centroids: [[Float]], k: Int) -> [Int] {
        var similarities: [(Int, Float)] = centroids.enumerated().map { (i, c) in
            (i, dotProduct(vector, c))
        }
        similarities.sort { $0.1 > $1.1 }
        return Array(similarities.prefix(k).map { $0.0 })
    }
    
    private func dotProduct(_ a: [Float], _ b: [Float]) -> Float {
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(dimensions))
        return result
    }
    
    private func squaredDistance(_ a: [Float], _ b: [Float]) -> Float {
        var diff = [Float](repeating: 0, count: dimensions)
        vDSP_vsub(b, 1, a, 1, &diff, 1, vDSP_Length(dimensions))
        var result: Float = 0
        vDSP_dotpr(diff, 1, diff, 1, &result, vDSP_Length(dimensions))
        return result
    }
    
    private func normalizeVector(_ vector: inout [Float]) {
        var sumSquared: Float = 0
        vDSP_dotpr(vector, 1, vector, 1, &sumSquared, vDSP_Length(dimensions))
        guard sumSquared > 1e-12 else { return }
        var invMagnitude = 1.0 / sqrtf(sumSquared)
        vDSP_vsmul(vector, 1, &invMagnitude, &vector, 1, vDSP_Length(dimensions))
    }
    
    /// Get cluster statistics for debugging
    public func clusterStats() -> [(centroidIdx: Int, vectorCount: Int)] {
        clusters.enumerated().map { ($0.offset, $0.element.frameIds.count) }
    }
}

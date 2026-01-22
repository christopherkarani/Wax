//
//  CosineDistance.metal
//  Wax
//
//  Metal compute shader for efficient vector similarity computation
//  Computes cosine distance between query vector and all database vectors in parallel
//

#include <metal_stdlib>
using namespace metal;

// Constants
constant uint kMaxThreadsPerThreadgroup = 256;

// Structure to pass vector data
struct VectorData {
    device const float* vectors;       // Flattened vector data [vectorCount * dimensions]
    device const float* query;         // Query vector [dimensions]
    device float* distances;           // Output distances [vectorCount]
    uint vectorCount;                 // Number of database vectors
    uint dimensions;                  // Vector dimensionality
};

// Kernel for computing cosine similarity (optimized for parallel execution)
kernel void cosineDistanceKernel(
    device const float* vectors [[buffer(0)]],      // Database vectors [vectorCount * dimensions]
    device const float* query [[buffer(1)]],        // Query vector [dimensions]
    device float* distances [[buffer(2)]],          // Output distances [vectorCount]
    constant uint& vectorCount [[buffer(3)]],        // Number of vectors
    constant uint& dimensions [[buffer(4)]],        // Vector dimensions
    uint2 gid [[thread_position_in_grid]],
    uint2 tid [[thread_position_in_threadgroup]]
) {
    // Each thread computes distance for one vector
    uint vectorIndex = gid.x;
    
    // Bounds check
    if (vectorIndex >= vectorCount) {
        return;
    }
    
    // Compute dot product (query · vector)
    float dotProduct = 0.0;
    float queryMagnitudeSquared = 0.0;
    float vectorMagnitudeSquared = 0.0;
    
    // Process in chunks to improve memory locality
    for (uint dim = 0; dim < dimensions; ++dim) {
        uint offset = vectorIndex * dimensions + dim;
        float vecValue = vectors[offset];
        float queryValue = query[dim];
        
        dotProduct += queryValue * vecValue;
        queryMagnitudeSquared += queryValue * queryValue;
        vectorMagnitudeSquared += vecValue * vecValue;
    }
    
    // Compute cosine similarity
    // cosine_sim = dot(a, b) / (||a|| * ||b||)
    // Convert to distance: distance = 1.0 - cosine_sim
    
    float magnitudeProduct = sqrt(queryMagnitudeSquared) * sqrt(vectorMagnitudeSquared);
    float cosineSimilarity = (magnitudeProduct > 1e-6) ? dotProduct / magnitudeProduct : 0.0;
    float cosineDistance = 1.0 - cosineSimilarity;
    
    distances[vectorIndex] = cosineDistance;
}

// Optimized version using threadgroup memory for better cache utilization
kernel void cosineDistanceKernelOptimized(
    device const float* vectors [[buffer(0)]],
    device const float* query [[buffer(1)]],
    device float* distances [[buffer(2)]],
    constant uint& vectorCount [[buffer(3)]],
    constant uint& dimensions [[buffer(4)]],
    threadgroup float* sharedQuery [[threadgroup(0)]],  // Shared query vector
    uint2 gid [[thread_position_in_grid]],
    uint tid [[thread_in_threadgroup]]
) {
    uint vectorIndex = gid.x;
    
    if (vectorIndex >= vectorCount) {
        return;
    }
    
    // Load query vector into threadgroup memory (only first threads participate)
    uint queryChunks = (dimensions + kMaxThreadsPerThreadgroup - 1) / kMaxThreadsPerThreadgroup;
    for (uint i = 0; i < queryChunks; ++i) {
        uint dim = tid * kMaxThreadsPerThreadgroup + i * kMaxThreadsPerThreadgroup;
        if (dim < dimensions) {
            sharedQuery[dim] = query[dim];
        }
    }
    
    // Synchronize to ensure query is fully loaded
    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    // Compute dot product using cached query
    float dotProduct = 0.0;
    float vectorMagnitudeSquared = 0.0;
    
    for (uint dim = 0; dim < dimensions; ++dim) {
        uint offset = vectorIndex * dimensions + dim;
        float vecValue = vectors[offset];
        float queryValue = sharedQuery[dim];
        
        dotProduct += queryValue * vecValue;
        vectorMagnitudeSquared += vecValue * vecValue;
    }
    
    // Pre-computed query magnitude could be passed as constant
    // For now, compute inline (assumes normalized query vectors)
    float magnitudeProduct = sqrt(vectorMagnitudeSquared);  // Assuming query is normalized (||q|| = 1)
    float cosineSimilarity = (magnitudeProduct > 1e-6) ? dotProduct / magnitudeProduct : 0.0;
    float cosineDistance = 1.0 - cosineSimilarity;
    
    distances[vectorIndex] = cosineDistance;
}

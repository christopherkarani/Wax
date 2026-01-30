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

// Optimized version using threadgroup memory and vectorized loads
kernel void cosineDistanceKernelOptimized(
    device const float* vectors [[buffer(0)]],
    device const float* query [[buffer(1)]],
    device float* distances [[buffer(2)]],
    constant uint& vectorCount [[buffer(3)]],
    constant uint& dimensions [[buffer(4)]],
    threadgroup float* sharedQuery [[threadgroup(0)]],  // Shared query vector
    uint2 gid [[thread_position_in_grid]],
    uint tid [[thread_index_in_threadgroup]]
) {
    uint vectorIndex = gid.x;
    
    if (vectorIndex >= vectorCount) {
        return;
    }
    
    // Load query vector into threadgroup memory (only first threads participate)
    // We can vectorize this too if dimensions is multiple of 4, but for safety kept scalar for now
    // Actually, let's vectorize the copy if possible.
    // Assuming dimensions is multiple of 4 is risky, so stick to scalar copy or careful vectorized copy.
    // Given shared memory bank conflicts, scalar copy is often fine or strided copy.
    
    uint queryChunks = (dimensions + kMaxThreadsPerThreadgroup - 1) / kMaxThreadsPerThreadgroup;
    for (uint i = 0; i < queryChunks; ++i) {
        uint dim = tid + i * kMaxThreadsPerThreadgroup;
        if (dim < dimensions) {
            sharedQuery[dim] = query[dim];
        }
    }
    
    // Synchronize to ensure query is fully loaded
    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    // Compute dot product using cached query and scalar loads with unrolling
    float dotProduct = 0.0;
    float vectorMagnitudeSquared = 0.0;
    
    uint vecOffset = vectorIndex * dimensions;
    
    // Unroll 4x
    uint i = 0;
    for (; i + 3 < dimensions; i += 4) {
        float v0 = vectors[vecOffset + i];
        float q0 = sharedQuery[i];
        dotProduct += q0 * v0;
        vectorMagnitudeSquared += v0 * v0;

        float v1 = vectors[vecOffset + i + 1];
        float q1 = sharedQuery[i + 1];
        dotProduct += q1 * v1;
        vectorMagnitudeSquared += v1 * v1;

        float v2 = vectors[vecOffset + i + 2];
        float q2 = sharedQuery[i + 2];
        dotProduct += q2 * v2;
        vectorMagnitudeSquared += v2 * v2;

        float v3 = vectors[vecOffset + i + 3];
        float q3 = sharedQuery[i + 3];
        dotProduct += q3 * v3;
        vectorMagnitudeSquared += v3 * v3;
    }

    // Handle remaining
    for (; i < dimensions; ++i) {
        float vecValue = vectors[vecOffset + i];
        float queryValue = sharedQuery[i];
        
        dotProduct += queryValue * vecValue;
        vectorMagnitudeSquared += vecValue * vecValue;
    }
    
    float magnitudeProduct = sqrt(vectorMagnitudeSquared);  // Assuming query is normalized (||q|| = 1)
    float cosineSimilarity = (magnitudeProduct > 1e-6) ? dotProduct / magnitudeProduct : 0.0;
    float cosineDistance = 1.0 - cosineSimilarity;
    
    distances[vectorIndex] = cosineDistance;
}

// SIMD float4 optimized kernel for 4x memory bandwidth improvement
// Requires dimensions to be divisible by 4 (MiniLM-L6 uses 384 dims = OK)
// Expects pre-normalized stored vectors (||v|| = 1) for maximum performance
kernel void cosineDistanceKernelSIMD(
    device const float* vectors [[buffer(0)]],      // Pre-normalized database vectors
    device const float* query [[buffer(1)]],        // Query vector (normalized)
    device float* distances [[buffer(2)]],          // Output distances
    constant uint& vectorCount [[buffer(3)]],       // Number of vectors
    constant uint& dimensions [[buffer(4)]],        // Vector dimensions (must be multiple of 4)
    threadgroup float4* sharedQueryVec [[threadgroup(0)]],  // Shared query as float4
    uint2 gid [[thread_position_in_grid]],
    uint tid [[thread_index_in_threadgroup]]
) {
    uint vectorIndex = gid.x;
    
    if (vectorIndex >= vectorCount) {
        return;
    }
    
    // Number of float4 elements
    uint dims4 = dimensions / 4;
    
    // Load query into threadgroup memory using SIMD float4 loads
    uint queryChunks4 = (dims4 + kMaxThreadsPerThreadgroup - 1) / kMaxThreadsPerThreadgroup;
    device const float4* queryVec4 = reinterpret_cast<device const float4*>(query);
    
    for (uint i = 0; i < queryChunks4; ++i) {
        uint dim4 = tid + i * kMaxThreadsPerThreadgroup;
        if (dim4 < dims4) {
            sharedQueryVec[dim4] = queryVec4[dim4];
        }
    }
    
    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    // SIMD dot product accumulation using float4 for 4x memory coalescing
    float4 dotAccum = float4(0.0);
    
    uint vecOffset4 = vectorIndex * dims4;
    device const float4* vectorsVec4 = reinterpret_cast<device const float4*>(vectors);
    
    // Main SIMD loop - 4 floats per iteration with unrolling
    uint i = 0;
    for (; i + 3 < dims4; i += 4) {
        // Load 4 float4s = 16 floats per iteration
        float4 v0 = vectorsVec4[vecOffset4 + i];
        float4 q0 = sharedQueryVec[i];
        dotAccum += q0 * v0;
        
        float4 v1 = vectorsVec4[vecOffset4 + i + 1];
        float4 q1 = sharedQueryVec[i + 1];
        dotAccum += q1 * v1;
        
        float4 v2 = vectorsVec4[vecOffset4 + i + 2];
        float4 q2 = sharedQueryVec[i + 2];
        dotAccum += q2 * v2;
        
        float4 v3 = vectorsVec4[vecOffset4 + i + 3];
        float4 q3 = sharedQueryVec[i + 3];
        dotAccum += q3 * v3;
    }
    
    // Handle remaining float4s
    for (; i < dims4; ++i) {
        float4 v = vectorsVec4[vecOffset4 + i];
        float4 q = sharedQueryVec[i];
        dotAccum += q * v;
    }
    
    // Reduce SIMD lanes to scalar
    float dotProduct = dotAccum.x + dotAccum.y + dotAccum.z + dotAccum.w;
    
    // Handle tail elements if dimensions not divisible by 4
    uint tailStart = dims4 * 4;
    for (uint j = tailStart; j < dimensions; ++j) {
        dotProduct += query[j] * vectors[vectorIndex * dimensions + j];
    }
    
    // For pre-normalized vectors: cosine_similarity = dot(q, v) since ||q|| = ||v|| = 1
    // cosine_distance = 1 - cosine_similarity
    float cosineDistance = 1.0 - dotProduct;
    
    distances[vectorIndex] = cosineDistance;
}


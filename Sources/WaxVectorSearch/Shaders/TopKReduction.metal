//
//  TopKReduction.metal
//  Wax
//
//  Optimized parallel top-k reduction using partial heap for small k,
//  falling back to bitonic sort for larger k values.
//  Each threadgroup processes a contiguous chunk of distances or entries,
//  produces sorted top-k, and merges across passes on GPU.
//

#include <metal_stdlib>
using namespace metal;

struct TopKEntry {
    float distance;
    uint index;
};

inline void swapEntries(threadgroup TopKEntry* entries, uint a, uint b) {
    TopKEntry temp = entries[a];
    entries[a] = entries[b];
    entries[b] = temp;
}

inline void siftDown(threadgroup TopKEntry* heap, uint start, uint end) {
    uint root = start;
    while (2 * root + 1 <= end) {
        uint child = 2 * root + 1;
        uint swapIdx = root;
        
        if (heap[swapIdx].distance < heap[child].distance) {
            swapIdx = child;
        }
        if (child + 1 <= end && heap[swapIdx].distance < heap[child + 1].distance) {
            swapIdx = child + 1;
        }
        if (swapIdx == root) {
            return;
        }
        swapEntries(heap, root, swapIdx);
        root = swapIdx;
    }
}

inline void heapify(threadgroup TopKEntry* heap, uint count) {
    if (count <= 1) return;
    int start = (count - 2) / 2;
    while (start >= 0) {
        siftDown(heap, start, count - 1);
        start--;
    }
}

inline void partialHeapTopK(threadgroup TopKEntry* data, uint count, uint k, uint tid, uint tgSize) {
    if (tid >= tgSize || k == 0 || count == 0) return;
    
    uint effectiveK = min(k, count);
    
    if (tid == 0) {
        heapify(data, effectiveK);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    for (uint i = effectiveK + tid; i < count; i += tgSize) {
        if (data[i].distance < data[0].distance) {
            if (tid == 0) {
                data[0] = data[i];
                siftDown(data, 0, effectiveK - 1);
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    
    if (tid == 0) {
        for (uint i = effectiveK - 1; i > 0; i--) {
            swapEntries(data, 0, i);
            siftDown(data, 0, i - 1);
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
}

inline void bitonicSortAscending(threadgroup TopKEntry* entries, uint tid, uint size) {
    for (uint k = 2; k <= size; k <<= 1) {
        for (uint j = k >> 1; j > 0; j >>= 1) {
            uint ixj = tid ^ j;
            if (ixj > tid) {
                bool ascending = ((tid & k) == 0);
                TopKEntry a = entries[tid];
                TopKEntry b = entries[ixj];
                bool shouldSwap = (a.distance > b.distance) == ascending;
                if (shouldSwap) {
                    entries[tid] = b;
                    entries[ixj] = a;
                }
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
    }
}

kernel void topKReduceDistances(
    device const float* distances [[buffer(0)]],
    constant uint& vectorCount [[buffer(1)]],
    constant uint& k [[buffer(2)]],
    device TopKEntry* outEntries [[buffer(3)]],
    threadgroup TopKEntry* sharedEntries [[threadgroup(0)]],
    uint tid [[thread_index_in_threadgroup]],
    uint tgId [[threadgroup_position_in_grid]],
    uint tgSize [[threads_per_threadgroup]]
) {
    uint baseIndex = tgId * tgSize;
    uint index = baseIndex + tid;
    if (index < vectorCount) {
        sharedEntries[tid] = TopKEntry{distances[index], index};
    } else {
        sharedEntries[tid] = TopKEntry{INFINITY, 0xFFFFFFFFu};
    }

    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    uint actualCount = min(tgSize, vectorCount - baseIndex);
    
    if (k <= 64 && actualCount > k * 4) {
        partialHeapTopK(sharedEntries, actualCount, k, tid, tgSize);
    } else {
        bitonicSortAscending(sharedEntries, tid, tgSize);
    }

    if (tid < k) {
        outEntries[tgId * k + tid] = sharedEntries[tid];
    }
}

kernel void topKReduceEntries(
    device const TopKEntry* entries [[buffer(0)]],
    constant uint& entryCount [[buffer(1)]],
    constant uint& k [[buffer(2)]],
    device TopKEntry* outEntries [[buffer(3)]],
    threadgroup TopKEntry* sharedEntries [[threadgroup(0)]],
    uint tid [[thread_index_in_threadgroup]],
    uint tgId [[threadgroup_position_in_grid]],
    uint tgSize [[threads_per_threadgroup]]
) {
    uint baseIndex = tgId * tgSize;
    uint index = baseIndex + tid;
    if (index < entryCount) {
        sharedEntries[tid] = entries[index];
    } else {
        sharedEntries[tid] = TopKEntry{INFINITY, 0xFFFFFFFFu};
    }

    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    uint actualCount = min(tgSize, entryCount - baseIndex);
    
    if (k <= 64 && actualCount > k * 4) {
        partialHeapTopK(sharedEntries, actualCount, k, tid, tgSize);
    } else {
        bitonicSortAscending(sharedEntries, tid, tgSize);
    }

    if (tid < k) {
        outEntries[tgId * k + tid] = sharedEntries[tid];
    }
}

#ifndef WAX_VECTOR_SCORES_H
#define WAX_VECTOR_SCORES_H

#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

/// Kernel choices for wax_vector_scores.
/// AUTO picks AVX2+FMA on x86-64 CPUs that have it, else GENERIC.
#define WAX_VECTOR_KERNEL_AUTO 0
/// GCC/Clang vector extensions with separate multiply and add: SSE2 on x86-64, NEON on
/// arm64. The same operations in the same order on both, so both give the same bits.
#define WAX_VECTOR_KERNEL_GENERIC 1
/// AVX2 with fused multiply-add, x86-64 only.
#define WAX_VECTOR_KERNEL_AVX2 2

/// The kernel wax_vector_scores runs for `requested`: AUTO resolves to the best kernel for
/// this CPU, and a kernel this CPU cannot run resolves to GENERIC.
int32_t wax_vector_kernel_resolve(int32_t requested);

/// Scores `row_count` row-major rows of `dim` floats against `query` into `scores`.
///
/// With `squared_norms` NULL, scores[r] is the dot product of row r and the query. Otherwise
/// scores[r] = -((squared_norms[r] + query_norm) - 2 * dot), rounded step by step without
/// fusing, which is the negative squared distance AccelerateVectorEngine reports for L2.
///
/// Each row is summed in a fixed order that depends only on `dim` and the kernel (sixteen
/// running lanes, then a fixed reduction tree, then the last dim % 8 values in order), never
/// on the row's position or the buffers' alignment, so splitting the rows across calls or
/// threads gives the same bits. Buffers need only Float alignment.
void wax_vector_scores(
    int32_t kernel,
    const float *rows,
    int64_t row_count,
    int64_t dim,
    const float *query,
    const float *squared_norms,
    float query_norm,
    float *scores
);

#if defined(__cplusplus)
}
#endif

#endif /* WAX_VECTOR_SCORES_H */

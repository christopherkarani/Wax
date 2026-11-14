#ifndef WAX_MIL_KERNELS_H
#define WAX_MIL_KERNELS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Single-precision matrix multiply, row-major:
///   C[m x n] = op(A)[m x k] * op(B)[k x n] + beta * C
/// op(A) is A when trans_a == 0 (A is m x k with row stride lda) and A^T otherwise (A is
/// k x m). Likewise for B (n x k when transposed). beta must be 0 (C is overwritten and may
/// hold garbage) or 1 (accumulate). Cache-blocked with packed panels; picks an AVX2+FMA
/// micro-kernel at run time on x86-64 CPUs that support it.
void wax_mil_sgemm(int trans_a, int trans_b,
                   size_t m, size_t n, size_t k,
                   const float *a, size_t lda,
                   const float *b, size_t ldb,
                   float beta,
                   float *c, size_t ldc);

/// 1 when wax_mil_sgemm uses the AVX2+FMA micro-kernel on this CPU, else 0.
int wax_mil_sgemm_uses_avx2(void);

/// Panel width of the micro-kernel; column ranges passed to wax_mil_sgemm_packed start on a
/// multiple of it.
#define WAX_MIL_SGEMM_NR 16

/// Number of floats wax_mil_sgemm_pack_b writes for an n x k op(B).
size_t wax_mil_sgemm_packed_b_count(size_t n, size_t k);

/// Packs op(B) (k x n; B is n x k with row stride ldb when trans_b != 0) once, for repeated
/// use by wax_mil_sgemm_packed, e.g. a constant weight matrix.
void wax_mil_sgemm_pack_b(int trans_b, size_t n, size_t k, const float *b, size_t ldb, float *packed);

/// Like wax_mil_sgemm with a pre-packed op(B), computing only columns [j_begin, j_end) of C.
/// j_begin is rounded down to a multiple of WAX_MIL_SGEMM_NR, so disjoint NR-aligned ranges
/// can run on different threads.
void wax_mil_sgemm_packed(int trans_a,
                          size_t m, size_t n, size_t k,
                          const float *a, size_t lda,
                          const float *packed_b,
                          size_t j_begin, size_t j_end,
                          float beta,
                          float *c, size_t ldc);

/// IEEE 754 binary16 to binary32, including subnormals, infinities and NaN.
void wax_mil_f16_to_f32(const uint16_t *src, float *dst, size_t count);

void wax_mil_i8_to_f32(const int8_t *src, float *dst, size_t count);
void wax_mil_u8_to_f32(const uint8_t *src, float *dst, size_t count);

/// In-place blockwise affine dequantisation: values[i] = (values[i] - offset[j]) * scale[j],
/// where j indexes `scale` (and `offset`, which may be NULL) by dividing each coordinate of i
/// by the block size shape[d] / scale_shape[d]. rank must be between 1 and 8.
void wax_mil_blockwise_dequantize(float *values, size_t rank, const size_t *shape,
                                  const float *scale, const float *offset,
                                  const size_t *scale_shape);

/// Layer normalisation over contiguous rows of `cols` elements. gamma and beta may be NULL.
void wax_mil_layer_norm(const float *x, float *y, size_t rows, size_t cols,
                        const float *gamma, const float *beta, float epsilon);

/// Softmax along the middle axis of an [outer, length, inner] view. Uses a vectorisable expf
/// (about 1 ulp) that returns exactly 0 for differences below about -87.3.
void wax_mil_softmax(const float *x, float *y, size_t outer, size_t length, size_t inner);

/// GELU. mode 0: exact, 0.5x(1 + erf(x / sqrt 2)) with a vectorisable erf (absolute error below
/// 1.5e-7); 1: tanh approximation; 2: sigmoid approximation x * sigmoid(1.702x).
void wax_mil_gelu(const float *x, float *y, size_t count, int mode);

void wax_mil_tanh(const float *x, float *y, size_t count);

#ifdef __cplusplus
}
#endif

#endif

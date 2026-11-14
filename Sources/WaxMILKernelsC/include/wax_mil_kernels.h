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

/// Softmax along the middle axis of an [outer, length, inner] view.
void wax_mil_softmax(const float *x, float *y, size_t outer, size_t length, size_t inner);

/// GELU. mode 0: exact (erf); 1: tanh approximation; 2: sigmoid approximation x*sigmoid(1.702x).
void wax_mil_gelu(const float *x, float *y, size_t count, int mode);

void wax_mil_tanh(const float *x, float *y, size_t count);

#ifdef __cplusplus
}
#endif

#endif

// Scoring kernel body, included once per instruction-set variant by wax_vector_scores.c
// with WAX_VS_NAME, WAX_VS_FINISH, WAX_VS_ATTR and WAX_VS_MADD(acc, a, b) defined. Not a
// public header.
//
// Every row runs the same operations in the same order, whether it falls in a 4-row block
// or the remainder: two 8-lane accumulators over 16-float steps, one more 8-float step when
// at least 8 floats remain, a fixed reduction tree, then the last dim % 8 products added in
// order. The 4-row block only interleaves four independent copies of that sequence.

// Accumulators come by pointer: a 32-byte vector argument would change the calling
// convention between the generic and AVX2 variants.
static inline __attribute__((always_inline)) WAX_VS_ATTR float WAX_VS_FINISH(
    const v8f *acc0_in, const v8f *acc1_in, const float *row, const float *query, int64_t from,
    int64_t dim, const float *norms, int64_t r, float query_norm
) {
    v8f acc0 = *acc0_in;
    int64_t d = from;
    if (dim - d >= 8) {
        acc0 = WAX_VS_MADD(acc0, WAX_LOAD8(row + d), WAX_LOAD8(query + d));
        d += 8;
    }
    const v8f acc = acc0 + *acc1_in;
    float sum = ((acc[0] + acc[4]) + (acc[2] + acc[6])) + ((acc[1] + acc[5]) + (acc[3] + acc[7]));
    for (; d < dim; ++d) {
        sum = sum + row[d] * query[d];
    }
    if (norms != 0) {
        // -(norm + query_norm - 2 * dot), one rounding per step as in the Swift engine.
        const float both = norms[r] + query_norm;
        const float twice = 2.0f * sum;
        sum = -(both - twice);
    }
    return sum;
}

static WAX_VS_ATTR void WAX_VS_NAME(
    const float *rows, int64_t row_count, int64_t dim, const float *query,
    const float *norms, float query_norm, float *scores
) {
    const int64_t d16 = dim / 16 * 16;
    const v8f zero = {0, 0, 0, 0, 0, 0, 0, 0};
    int64_t r = 0;
    for (; r + 4 <= row_count; r += 4) {
        const float *r0 = rows + r * dim;
        const float *r1 = r0 + dim;
        const float *r2 = r1 + dim;
        const float *r3 = r2 + dim;
        v8f a00 = zero, a01 = zero, a10 = zero, a11 = zero;
        v8f a20 = zero, a21 = zero, a30 = zero, a31 = zero;
        for (int64_t d = 0; d < d16; d += 16) {
            const v8f q0 = WAX_LOAD8(query + d);
            const v8f q1 = WAX_LOAD8(query + d + 8);
            a00 = WAX_VS_MADD(a00, WAX_LOAD8(r0 + d), q0);
            a01 = WAX_VS_MADD(a01, WAX_LOAD8(r0 + d + 8), q1);
            a10 = WAX_VS_MADD(a10, WAX_LOAD8(r1 + d), q0);
            a11 = WAX_VS_MADD(a11, WAX_LOAD8(r1 + d + 8), q1);
            a20 = WAX_VS_MADD(a20, WAX_LOAD8(r2 + d), q0);
            a21 = WAX_VS_MADD(a21, WAX_LOAD8(r2 + d + 8), q1);
            a30 = WAX_VS_MADD(a30, WAX_LOAD8(r3 + d), q0);
            a31 = WAX_VS_MADD(a31, WAX_LOAD8(r3 + d + 8), q1);
        }
        scores[r] = WAX_VS_FINISH(&a00, &a01, r0, query, d16, dim, norms, r, query_norm);
        scores[r + 1] = WAX_VS_FINISH(&a10, &a11, r1, query, d16, dim, norms, r + 1, query_norm);
        scores[r + 2] = WAX_VS_FINISH(&a20, &a21, r2, query, d16, dim, norms, r + 2, query_norm);
        scores[r + 3] = WAX_VS_FINISH(&a30, &a31, r3, query, d16, dim, norms, r + 3, query_norm);
    }
    for (; r < row_count; ++r) {
        const float *row = rows + r * dim;
        v8f a0 = zero, a1 = zero;
        for (int64_t d = 0; d < d16; d += 16) {
            a0 = WAX_VS_MADD(a0, WAX_LOAD8(row + d), WAX_LOAD8(query + d));
            a1 = WAX_VS_MADD(a1, WAX_LOAD8(row + d + 8), WAX_LOAD8(query + d + 8));
        }
        scores[r] = WAX_VS_FINISH(&a0, &a1, row, query, d16, dim, norms, r, query_norm);
    }
}

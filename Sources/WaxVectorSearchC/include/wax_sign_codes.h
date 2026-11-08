#ifndef WAX_SIGN_CODES_H
#define WAX_SIGN_CODES_H

#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

/// Query bit planes used by the sign-code scan.
#define WAX_SIGN_CODE_QUERY_PLANES 4

/// Encodes `row_count` rows of `dim` floats as sign bits (bit d set when row[d] > 0),
/// `words` u64 per row with unused high bits zero. Also writes, per row, the number of
/// set bits and the mean absolute value (the least-squares scale of the sign code).
void wax_sign_codes_encode(
    const float *rows,
    int64_t row_count,
    int64_t dim,
    int64_t words,
    uint64_t *codes,
    uint32_t *popcounts,
    float *mean_abs
);

/// Quantizes `query` to 4-bit levels and writes them as WAX_SIGN_CODE_QUERY_PLANES bit
/// planes of `words` u64 (plane b holds bit b of each level). The estimate for row r is
///   est_r = mean_abs[r] * (a * S_r + b * popcounts[r] + c),
/// with S_r = sum_b 2^b popcount(plane_b & code_r); that equals mean_abs[r] times the
/// dot product of the dequantized query with the row's +-1 sign vector.
void wax_sign_codes_query(
    const float *query,
    int64_t dim,
    int64_t words,
    uint64_t *planes,
    float *a,
    float *b,
    float *c
);

/// Scans `row_count` rows and keeps the `cap` rows with the largest estimates in a
/// min-heap (`heap_scores`, `heap_rows`, both `cap` long). Rows are numbered from 0 within
/// this call. Returns the number of entries kept (min(cap, row_count)). Ties at the cut
/// keep the earlier row, so results are deterministic.
int64_t wax_sign_codes_scan_top(
    const uint64_t *codes,
    const uint32_t *popcounts,
    const float *mean_abs,
    int64_t row_count,
    int64_t words,
    const uint64_t *planes,
    float a,
    float b,
    float c,
    int64_t cap,
    float *heap_scores,
    uint32_t *heap_rows
);

/// Keeps the `cap` largest of `scores` in a min-heap, like wax_sign_codes_scan_top.
int64_t wax_top_scores(
    const float *scores,
    int64_t count,
    int64_t cap,
    float *heap_scores,
    uint32_t *heap_indices
);

#if defined(__cplusplus)
}
#endif

#endif /* WAX_SIGN_CODES_H */

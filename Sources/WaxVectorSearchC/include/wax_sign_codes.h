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

/// Rows per block of the blocked code layout. Byte j of row r (dimensions 8j..8j+7, bit i
/// is dimension 8j+i) lives at blocked[((r / 16) * bytes + j) * 16 + r % 16], with
/// bytes = words * 8, so one 16-byte load holds that byte of 16 rows. Storage covers
/// whole blocks.
#define WAX_SIGN_CODE_BLOCK_ROWS 16

/// Hints the cache to load `bytes` bytes at `address` (one hint per 128-byte line). Used to
/// overlap the loads of rows about to be rescored; it has no effect on results.
static inline void wax_prefetch(const void *address, int64_t bytes) {
    const char *base = (const char *)address;
    for (int64_t offset = 0; offset < bytes; offset += 128) {
        __builtin_prefetch(base + offset);
    }
}

/// Writes `row_count` row-major codes (`words` u64 per row) into the blocked layout as rows
/// first_row..first_row+row_count-1.
void wax_sign_codes_store_blocked(
    const uint64_t *codes,
    int64_t row_count,
    int64_t words,
    uint8_t *blocked,
    int64_t first_row
);

/// Copies row `from_row` of the blocked layout over row `to_row`.
void wax_sign_codes_copy_blocked_row(uint8_t *blocked, int64_t words, int64_t from_row, int64_t to_row);

/// Lookup tables for a query's planes: for nibble k (dimensions 4k..4k+3), entry n is the
/// sum of the 4-bit levels of the dimensions whose bits are set in n. `tables` holds
/// words * 16 tables of 16 bytes.
void wax_sign_codes_query_tables(const uint64_t *planes, int64_t words, uint8_t *tables);

/// Scans `row_count` rows of the blocked layout (`blocked` starts at a block boundary) and
/// keeps the `cap` rows with the largest estimates in a min-heap (`heap_scores`,
/// `heap_rows`, both `cap` long). The estimate is the one documented for
/// wax_sign_codes_query, S_r summed from `tables`. Rows are numbered from 0 within this
/// call. Returns the number of entries kept (min(cap, row_count)). Ties at the cut keep
/// the earlier row, so results are deterministic.
int64_t wax_sign_codes_scan_top_blocked(
    const uint8_t *blocked,
    const uint32_t *popcounts,
    const float *mean_abs,
    int64_t row_count,
    int64_t words,
    const uint8_t *tables,
    float a,
    float b,
    float c,
    int64_t cap,
    float *heap_scores,
    uint32_t *heap_rows
);

/// Keeps the `cap` largest of `scores` in a min-heap, like wax_sign_codes_scan_top_blocked.
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

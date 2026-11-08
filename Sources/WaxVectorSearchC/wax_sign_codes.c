#include "wax_sign_codes.h"

#include <math.h>  /* INFINITY only: no libm calls, so nothing extra to link on Linux. */

#if defined(__aarch64__) && defined(__ARM_NEON)
#include <arm_neon.h>
#define WAX_SIGN_CODES_NEON 1
#endif

/// Rows scored per block before selection; the block's best estimate gates the heap.
#define WAX_SIGN_CODES_BLOCK 64

static inline float wax_abs(float value) {
    return value < 0 ? -value : value;
}

void wax_sign_codes_encode(
    const float *rows,
    int64_t row_count,
    int64_t dim,
    int64_t words,
    uint64_t *codes,
    uint32_t *popcounts,
    float *mean_abs
) {
    for (int64_t r = 0; r < row_count; ++r) {
        const float *row = rows + r * dim;
        uint64_t *code = codes + r * words;
        uint32_t set = 0;
        for (int64_t w = 0; w < words; ++w) {
            const int64_t start = w * 64;
            const int64_t end = start + 64 < dim ? start + 64 : dim;
            uint64_t bits = 0;
            // Branchless: signs are coin flips, so a branch here mispredicts half the time.
            for (int64_t d = start; d < end; ++d) {
                bits |= (uint64_t)(row[d] > 0) << (d - start);
            }
            code[w] = bits;
            set += (uint32_t)__builtin_popcountll(bits);
        }
        // Eight independent partial sums so the loop vectorizes under strict FP rules.
        float partial[8] = {0, 0, 0, 0, 0, 0, 0, 0};
        int64_t d = 0;
        for (; d + 8 <= dim; d += 8) {
            for (int lane = 0; lane < 8; ++lane) partial[lane] += wax_abs(row[d + lane]);
        }
        float abs_sum = 0;
        for (; d < dim; ++d) abs_sum += wax_abs(row[d]);
        for (int lane = 0; lane < 8; ++lane) abs_sum += partial[lane];
        popcounts[r] = set;
        mean_abs[r] = abs_sum / (float)dim;
    }
}

void wax_sign_codes_query(
    const float *query,
    int64_t dim,
    int64_t words,
    uint64_t *planes,
    float *a,
    float *b,
    float *c
) {
    for (int64_t i = 0; i < WAX_SIGN_CODE_QUERY_PLANES * words; ++i) planes[i] = 0;
    float lo = query[0], hi = query[0];
    for (int64_t d = 1; d < dim; ++d) {
        lo = query[d] < lo ? query[d] : lo;
        hi = query[d] > hi ? query[d] : hi;
    }
    const int levels = (1 << WAX_SIGN_CODE_QUERY_PLANES) - 1;
    const float step = (hi - lo) / (float)levels;
    double dequantized_sum = 0;
    for (int64_t d = 0; d < dim; ++d) {
        int level = 0;
        if (step > 0) {
            // (query[d] - lo) / step is in [0, levels]; adding 0.5 and truncating rounds it.
            level = (int)((query[d] - lo) / step + 0.5f);
            level = level < 0 ? 0 : (level > levels ? levels : level);
        }
        for (int plane = 0; plane < WAX_SIGN_CODE_QUERY_PLANES; ++plane) {
            if ((level >> plane) & 1) {
                planes[plane * words + (d >> 6)] |= (uint64_t)1 << (d & 63);
            }
        }
        dequantized_sum += (double)lo + (double)step * (double)level;
    }
    // sum_d q~_d * sign_d = 2 * sum_{bit set} q~_d - sum_d q~_d
    //                     = 2*step*S + 2*lo*popcount - sum_d q~_d
    *a = 2 * step;
    *b = 2 * lo;
    *c = (float)-dequantized_sum;
}

static inline uint32_t weighted_popcount_scalar(const uint64_t *code, const uint64_t *planes, int64_t words, int64_t from_word) {
    uint32_t total = 0;
    for (int64_t w = from_word; w < words; ++w) {
        for (int plane = 0; plane < WAX_SIGN_CODE_QUERY_PLANES; ++plane) {
            total += (uint32_t)__builtin_popcountll(code[w] & planes[plane * words + w]) << plane;
        }
    }
    return total;
}

#if defined(WAX_SIGN_CODES_NEON)
/// Max 16-byte vectors per u16 accumulation run: each step adds at most 2*120 per lane.
#define WAX_SIGN_CODES_FLUSH_VECTORS 256

/// Weighted popcount of one row over its first `vectors` 16-byte chunks.
static inline __attribute__((always_inline)) uint32_t weighted_popcount_neon(const uint8_t *row, const uint64_t *planes, int64_t words, int64_t vectors) {
    const uint8_t *p0 = (const uint8_t *)planes;
    const uint8_t *p1 = (const uint8_t *)(planes + words);
    const uint8_t *p2 = (const uint8_t *)(planes + 2 * words);
    const uint8_t *p3 = (const uint8_t *)(planes + 3 * words);
    const uint8x16_t two = vdupq_n_u8(2), four = vdupq_n_u8(4), eight = vdupq_n_u8(8);
    uint32_t total = 0;
    for (int64_t start = 0; start < vectors; start += WAX_SIGN_CODES_FLUSH_VECTORS) {
        int64_t end = start + WAX_SIGN_CODES_FLUSH_VECTORS < vectors ? start + WAX_SIGN_CODES_FLUSH_VECTORS : vectors;
        uint16x8_t acc = vdupq_n_u16(0);
        for (int64_t v = start; v < end; ++v) {
            uint8x16_t code = vld1q_u8(row + 16 * v);
            // Per byte: sum_b 2^b * popcount(byte & plane_b) <= 8 * 15 = 120.
            uint8x16_t w = vcntq_u8(vandq_u8(code, vld1q_u8(p0 + 16 * v)));
            w = vmlaq_u8(w, vcntq_u8(vandq_u8(code, vld1q_u8(p1 + 16 * v))), two);
            w = vmlaq_u8(w, vcntq_u8(vandq_u8(code, vld1q_u8(p2 + 16 * v))), four);
            w = vmlaq_u8(w, vcntq_u8(vandq_u8(code, vld1q_u8(p3 + 16 * v))), eight);
            acc = vpadalq_u8(acc, w);
        }
        total += vaddlvq_u16(acc);
    }
    return total;
}
#endif

static inline void heap_sift_up(float *scores, uint32_t *rows, int64_t index) {
    while (index > 0) {
        int64_t parent = (index - 1) / 2;
        if (scores[parent] <= scores[index]) return;
        float s = scores[parent]; scores[parent] = scores[index]; scores[index] = s;
        uint32_t r = rows[parent]; rows[parent] = rows[index]; rows[index] = r;
        index = parent;
    }
}

static inline void heap_sift_down(float *scores, uint32_t *rows, int64_t count) {
    int64_t index = 0;
    for (;;) {
        int64_t left = 2 * index + 1;
        if (left >= count) return;
        int64_t smallest = left;
        if (left + 1 < count && scores[left + 1] < scores[left]) smallest = left + 1;
        if (scores[smallest] >= scores[index]) return;
        float s = scores[smallest]; scores[smallest] = scores[index]; scores[index] = s;
        uint32_t r = rows[smallest]; rows[smallest] = rows[index]; rows[index] = r;
        index = smallest;
    }
}

/// Min-heap admission: fills to `cap`, then replaces the root only on a strictly larger score.
static inline void heap_offer(float *scores, uint32_t *rows, int64_t *count, int64_t cap, float score, uint32_t row) {
    if (*count < cap) {
        scores[*count] = score;
        rows[*count] = row;
        heap_sift_up(scores, rows, *count);
        *count += 1;
    } else if (score > scores[0]) {
        scores[0] = score;
        rows[0] = row;
        heap_sift_down(scores, rows, *count);
    }
}

/// The scan proper. Inlined per common width so `vectors` is a constant and the query
/// planes stay in registers across rows.
static inline __attribute__((always_inline)) int64_t scan_top_impl(
    const uint64_t *codes,
    const uint32_t *popcounts,
    const float *mean_abs,
    int64_t row_count,
    int64_t words,
    int64_t vectors,
    const uint64_t *planes,
    float a,
    float b,
    float c,
    int64_t cap,
    float *heap_scores,
    uint32_t *heap_rows
) {
    float estimates[WAX_SIGN_CODES_BLOCK];
    int64_t kept = 0;
    for (int64_t base = 0; base < row_count; base += WAX_SIGN_CODES_BLOCK) {
        int64_t block = row_count - base < WAX_SIGN_CODES_BLOCK ? row_count - base : WAX_SIGN_CODES_BLOCK;
        float best = -INFINITY;
        for (int64_t i = 0; i < block; ++i) {
            int64_t r = base + i;
            const uint64_t *code = codes + r * words;
            uint32_t weighted = 0;
#if defined(WAX_SIGN_CODES_NEON)
            weighted = weighted_popcount_neon((const uint8_t *)code, planes, words, vectors);
#endif
            weighted += weighted_popcount_scalar(code, planes, words, 2 * vectors);
            float estimate = mean_abs[r] * (a * (float)weighted + b * (float)popcounts[r] + c);
            estimates[i] = estimate;
            best = estimate > best ? estimate : best;
        }
        if (kept == cap && !(best > heap_scores[0])) continue;
        for (int64_t i = 0; i < block; ++i) {
            heap_offer(heap_scores, heap_rows, &kept, cap, estimates[i], (uint32_t)(base + i));
        }
    }
    return kept;
}

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
) {
    if (cap <= 0) return 0;
#if defined(WAX_SIGN_CODES_NEON)
    const int64_t vectors = words / 2;
#else
    const int64_t vectors = 0;
#endif
#define WAX_SCAN(V) scan_top_impl(codes, popcounts, mean_abs, row_count, words, (V), planes, a, b, c, cap, heap_scores, heap_rows)
    switch (vectors) {
    case 2: return WAX_SCAN(2);   // 256 dims
    case 3: return WAX_SCAN(3);   // 384 dims
    case 4: return WAX_SCAN(4);   // 512 dims
    case 6: return WAX_SCAN(6);   // 768 dims
    case 8: return WAX_SCAN(8);   // 1024 dims
    default: return WAX_SCAN(vectors);
    }
#undef WAX_SCAN
}

int64_t wax_top_scores(
    const float *scores,
    int64_t count,
    int64_t cap,
    float *heap_scores,
    uint32_t *heap_indices
) {
    if (cap <= 0) return 0;
    int64_t kept = 0;
    for (int64_t i = 0; i < count; ++i) {
        heap_offer(heap_scores, heap_indices, &kept, cap, scores[i], (uint32_t)i);
    }
    return kept;
}

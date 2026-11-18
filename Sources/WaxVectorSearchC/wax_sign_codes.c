#include "wax_sign_codes.h"

#include <math.h>  /* INFINITY only: no libm calls, so nothing extra to link on Linux. */

#if defined(__aarch64__) && defined(__ARM_NEON)
#include <arm_neon.h>
#define WAX_SIGN_CODES_NEON 1
#endif

/// Rows scored per group (four blocks) before selection; the group's best estimate gates
/// the heap.
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

static inline int64_t blocked_offset(int64_t row, int64_t bytes, int64_t byte) {
    return ((row / WAX_SIGN_CODE_BLOCK_ROWS) * bytes + byte) * WAX_SIGN_CODE_BLOCK_ROWS
        + row % WAX_SIGN_CODE_BLOCK_ROWS;
}

void wax_sign_codes_store_blocked(
    const uint64_t *codes,
    int64_t row_count,
    int64_t words,
    uint8_t *blocked,
    int64_t first_row
) {
    const int64_t bytes = words * 8;
    for (int64_t r = 0; r < row_count; ++r) {
        const uint64_t *code = codes + r * words;
        const int64_t row = first_row + r;
        for (int64_t j = 0; j < bytes; ++j) {
            // Byte j holds dimensions 8j..8j+7, bit i dimension 8j+i, on any endianness.
            blocked[blocked_offset(row, bytes, j)] = (uint8_t)(code[j / 8] >> (8 * (j % 8)));
        }
    }
}

void wax_sign_codes_copy_blocked_row(uint8_t *blocked, int64_t words, int64_t from_row, int64_t to_row) {
    const int64_t bytes = words * 8;
    for (int64_t j = 0; j < bytes; ++j) {
        blocked[blocked_offset(to_row, bytes, j)] = blocked[blocked_offset(from_row, bytes, j)];
    }
}

void wax_sign_codes_query_tables(const uint64_t *planes, int64_t words, uint8_t *tables) {
    const int64_t nibbles = words * 16;
    for (int64_t k = 0; k < nibbles; ++k) {
        int level[4];
        for (int i = 0; i < 4; ++i) {
            const int64_t d = 4 * k + i;
            int value = 0;
            for (int plane = 0; plane < WAX_SIGN_CODE_QUERY_PLANES; ++plane) {
                value |= (int)((planes[plane * words + d / 64] >> (d % 64)) & 1) << plane;
            }
            level[i] = value;
        }
        for (int nibble = 0; nibble < 16; ++nibble) {
            int sum = 0;
            for (int i = 0; i < 4; ++i) {
                if ((nibble >> i) & 1) sum += level[i];
            }
            tables[k * 16 + nibble] = (uint8_t)sum;
        }
    }
}

/// est = mean_abs * ((a * weighted + b * popcount) + c), one rounding per operation and
/// never fused, so the vector path below produces the same bits.
static inline float estimate(float mean_abs, uint32_t weighted, uint32_t popcount, float a, float b, float c) {
    const float aw = a * (float)weighted;
    const float bp = b * (float)popcount;
    const float sum = aw + bp;
    const float shifted = sum + c;
    return mean_abs * shifted;
}

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

/// Weighted popcounts of the `count` rows of one group (from a block boundary), one
/// table lookup per nibble.
static void group_weights_scalar(
    const uint8_t *group,
    int64_t count,
    int64_t bytes,
    const uint8_t *tables,
    uint32_t *weighted
) {
    for (int64_t i = 0; i < count; ++i) {
        uint32_t total = 0;
        for (int64_t j = 0; j < bytes; ++j) {
            const uint8_t value = group[blocked_offset(i, bytes, j)];
            total += tables[(2 * j) * 16 + (value & 0x0F)] + tables[(2 * j + 1) * 16 + (value >> 4)];
        }
        weighted[i] = total;
    }
}

#if defined(WAX_SIGN_CODES_NEON)
/// Widest row whose weighted popcount fits the u16 lanes: 15 per dimension.
#define WAX_SIGN_CODES_NEON_MAX_BYTES 546

/// Same as group_weights_scalar for up to four blocks: per 16 rows of a block, two table
/// lookups (vqtbl1q) per code byte.
static inline __attribute__((always_inline)) void group_weights_neon(
    const uint8_t *group,
    int64_t blocks,
    int64_t bytes,
    const uint8_t *tables,
    uint32_t *weighted
) {
    const uint8x16_t low = vdupq_n_u8(0x0F);
    uint16x8_t acc[8];
    for (int i = 0; i < 8; ++i) acc[i] = vdupq_n_u16(0);
    for (int64_t j = 0; j < bytes; j += 2) {
        const uint8x16_t t0 = vld1q_u8(tables + (2 * j) * 16);
        const uint8x16_t t1 = vld1q_u8(tables + (2 * j + 1) * 16);
        const uint8x16_t t2 = vld1q_u8(tables + (2 * j + 2) * 16);
        const uint8x16_t t3 = vld1q_u8(tables + (2 * j + 3) * 16);
        for (int64_t block = 0; block < blocks; ++block) {
            const uint8_t *base = group + (block * bytes + j) * WAX_SIGN_CODE_BLOCK_ROWS;
            const uint8x16_t v0 = vld1q_u8(base);
            const uint8x16_t v1 = vld1q_u8(base + WAX_SIGN_CODE_BLOCK_ROWS);
            // Four lookups of at most 60 each stay within a byte.
            uint8x16_t sum = vaddq_u8(vqtbl1q_u8(t0, vandq_u8(v0, low)), vqtbl1q_u8(t1, vshrq_n_u8(v0, 4)));
            sum = vaddq_u8(sum, vqtbl1q_u8(t2, vandq_u8(v1, low)));
            sum = vaddq_u8(sum, vqtbl1q_u8(t3, vshrq_n_u8(v1, 4)));
            acc[2 * block] = vaddw_u8(acc[2 * block], vget_low_u8(sum));
            acc[2 * block + 1] = vaddw_high_u8(acc[2 * block + 1], sum);
        }
    }
    for (int64_t block = 0; block < blocks; ++block) {
        for (int half = 0; half < 2; ++half) {
            const uint16x8_t lanes = acc[2 * block + half];
            uint32_t *out = weighted + block * WAX_SIGN_CODE_BLOCK_ROWS + half * 8;
            vst1q_u32(out, vmovl_u16(vget_low_u16(lanes)));
            vst1q_u32(out + 4, vmovl_high_u16(lanes));
        }
    }
}
#endif

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
) {
    if (cap <= 0) return 0;
    const int64_t bytes = words * 8;
    uint32_t weighted[WAX_SIGN_CODES_BLOCK];
    float estimates[WAX_SIGN_CODES_BLOCK];
    int64_t kept = 0;
    for (int64_t base = 0; base < row_count; base += WAX_SIGN_CODES_BLOCK) {
        const int64_t count = row_count - base < WAX_SIGN_CODES_BLOCK ? row_count - base : WAX_SIGN_CODES_BLOCK;
        const uint8_t *group = blocked + (base / WAX_SIGN_CODE_BLOCK_ROWS) * bytes * WAX_SIGN_CODE_BLOCK_ROWS;
        float best = -INFINITY;
        int estimated = 0;
#if defined(WAX_SIGN_CODES_NEON)
        if (bytes <= WAX_SIGN_CODES_NEON_MAX_BYTES) {
            const int64_t blocks = (count + WAX_SIGN_CODE_BLOCK_ROWS - 1) / WAX_SIGN_CODE_BLOCK_ROWS;
            if (blocks == 4) {
                group_weights_neon(group, 4, bytes, tables, weighted);
            } else {
                group_weights_neon(group, blocks, bytes, tables, weighted);
            }
        } else {
            group_weights_scalar(group, count, bytes, tables, weighted);
        }
        if (count == WAX_SIGN_CODES_BLOCK) {
            const float32x4_t va = vdupq_n_f32(a), vb = vdupq_n_f32(b), vc = vdupq_n_f32(c);
            float32x4_t lanes_best = vdupq_n_f32(-INFINITY);
            for (int64_t i = 0; i < WAX_SIGN_CODES_BLOCK; i += 4) {
                const float32x4_t aw = vmulq_f32(va, vcvtq_f32_u32(vld1q_u32(weighted + i)));
                const float32x4_t bp = vmulq_f32(vb, vcvtq_f32_u32(vld1q_u32(popcounts + base + i)));
                const float32x4_t shifted = vaddq_f32(vaddq_f32(aw, bp), vc);
                const float32x4_t value = vmulq_f32(vld1q_f32(mean_abs + base + i), shifted);
                vst1q_f32(estimates + i, value);
                // maxNum ignores NaN, like the scalar comparison below.
                lanes_best = vmaxnmq_f32(lanes_best, value);
            }
            best = vmaxnmvq_f32(lanes_best);
            estimated = 1;
        }
#else
        group_weights_scalar(group, count, bytes, tables, weighted);
#endif
        if (!estimated) {
            for (int64_t i = 0; i < count; ++i) {
                const float value = estimate(mean_abs[base + i], weighted[i], popcounts[base + i], a, b, c);
                estimates[i] = value;
                best = value > best ? value : best;
            }
        }
        if (kept == cap && !(best > heap_scores[0])) continue;
        for (int64_t i = 0; i < count; ++i) {
            heap_offer(heap_scores, heap_rows, &kept, cap, estimates[i], (uint32_t)(base + i));
        }
    }
    return kept;
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

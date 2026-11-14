#include "wax_mil_kernels.h"

#include <stdlib.h>
#include <string.h>

#if defined(__x86_64__) && (defined(__clang__) || defined(__GNUC__))
#include <cpuid.h>
#define WAX_X86_DISPATCH 1
#else
#define WAX_X86_DISPATCH 0
#endif

// Register tile and cache blocking. MC x KC panels of A (96 KB) stay in L2, KC x NC panels of
// B (512 KB) in L2/L3, and each kc x NR sliver of B in L1.
#define WAX_MR 6
#define WAX_NR 16
#define WAX_KC 256
#define WAX_MC 96
#define WAX_NC 512
_Static_assert(WAX_NR == WAX_MIL_SGEMM_NR, "public panel width must match the micro-kernel");
_Static_assert(WAX_NC % WAX_NR == 0, "column blocks must be whole panels");

typedef float v8f __attribute__((vector_size(32)));
#define wax_splat(x) ((v8f){(x), (x), (x), (x), (x), (x), (x), (x)})

#define WAX_KERNEL_NAME wax_macro_kernel_generic
#define WAX_KERNEL_ATTR
#include "wax_mil_sgemm_kernel.h"
#undef WAX_KERNEL_NAME
#undef WAX_KERNEL_ATTR

#if WAX_X86_DISPATCH
#define WAX_KERNEL_NAME wax_macro_kernel_avx2
#define WAX_KERNEL_ATTR __attribute__((target("avx2,fma")))
#include "wax_mil_sgemm_kernel.h"
#undef WAX_KERNEL_NAME
#undef WAX_KERNEL_ATTR

static int wax_detect_avx2_fma(void) {
    unsigned int eax, ebx, ecx, edx;
    if (!__get_cpuid(1, &eax, &ebx, &ecx, &edx)) return 0;
    const int fma = (ecx >> 12) & 1;
    const int osxsave = (ecx >> 27) & 1;
    const int avx = (ecx >> 28) & 1;
    if (!(fma && osxsave && avx)) return 0;
    unsigned int xcr0_lo, xcr0_hi;
    __asm__ volatile("xgetbv" : "=a"(xcr0_lo), "=d"(xcr0_hi) : "c"(0));
    (void)xcr0_hi;
    if ((xcr0_lo & 0x6) != 0x6) return 0; // OS saves XMM and YMM state
    if (__get_cpuid_max(0, NULL) < 7) return 0;
    __cpuid_count(7, 0, eax, ebx, ecx, edx);
    return (ebx >> 5) & 1;
}

// 0 = not yet detected, 1 = generic, 2 = AVX2+FMA. Racing first calls compute the same value.
static int wax_kernel_choice = 0;

static int wax_use_avx2(void) {
    int choice = __atomic_load_n(&wax_kernel_choice, __ATOMIC_RELAXED);
    if (choice == 0) {
        choice = wax_detect_avx2_fma() ? 2 : 1;
        __atomic_store_n(&wax_kernel_choice, choice, __ATOMIC_RELAXED);
    }
    return choice == 2;
}
#endif

int wax_mil_sgemm_uses_avx2(void) {
#if WAX_X86_DISPATCH
    return wax_use_avx2();
#else
    return 0;
#endif
}

static void *wax_aligned_alloc(size_t bytes) {
    void *pointer = NULL;
    if (posix_memalign(&pointer, 64, bytes == 0 ? 64 : bytes) != 0) return NULL;
    return pointer;
}

// Packs op(A)[i0 : i0+mc, p0 : p0+kc] into MR-row panels, zero-padding the last panel.
static void wax_pack_a(int trans_a, const float *a, size_t lda, size_t i0, size_t mc,
                       size_t p0, size_t kc, float *restrict ap) {
    for (size_t ir = 0; ir < mc; ir += WAX_MR) {
        const size_t mr = (mc - ir) < WAX_MR ? (mc - ir) : WAX_MR;
        float *panel = ap + (ir / WAX_MR) * kc * WAX_MR;
        if (!trans_a) {
            for (size_t ii = 0; ii < WAX_MR; ii++) {
                if (ii < mr) {
                    const float *row = a + (i0 + ir + ii) * lda + p0;
                    for (size_t p = 0; p < kc; p++) panel[p * WAX_MR + ii] = row[p];
                } else {
                    for (size_t p = 0; p < kc; p++) panel[p * WAX_MR + ii] = 0.0f;
                }
            }
        } else {
            for (size_t p = 0; p < kc; p++) {
                const float *column = a + (p0 + p) * lda + i0 + ir;
                size_t ii = 0;
                for (; ii < mr; ii++) panel[p * WAX_MR + ii] = column[ii];
                for (; ii < WAX_MR; ii++) panel[p * WAX_MR + ii] = 0.0f;
            }
        }
    }
}

// Packs op(B)[p0 : p0+kc, j0 : j0+nc] into NR-column panels, zero-padding the last panel.
static void wax_pack_b(int trans_b, const float *b, size_t ldb, size_t p0, size_t kc,
                       size_t j0, size_t nc, float *restrict bp) {
    for (size_t jr = 0; jr < nc; jr += WAX_NR) {
        const size_t nr = (nc - jr) < WAX_NR ? (nc - jr) : WAX_NR;
        float *panel = bp + (jr / WAX_NR) * kc * WAX_NR;
        if (!trans_b) {
            for (size_t p = 0; p < kc; p++) {
                const float *row = b + (p0 + p) * ldb + j0 + jr;
                size_t jj = 0;
                for (; jj < nr; jj++) panel[p * WAX_NR + jj] = row[jj];
                for (; jj < WAX_NR; jj++) panel[p * WAX_NR + jj] = 0.0f;
            }
        } else {
            for (size_t jj = 0; jj < WAX_NR; jj++) {
                if (jj < nr) {
                    const float *column = b + (j0 + jr + jj) * ldb + p0;
                    for (size_t p = 0; p < kc; p++) panel[p * WAX_NR + jj] = column[p];
                } else {
                    for (size_t p = 0; p < kc; p++) panel[p * WAX_NR + jj] = 0.0f;
                }
            }
        }
    }
}

static void wax_sgemm_naive(int trans_a, int trans_b, size_t m, size_t n, size_t k,
                            const float *a, size_t lda, const float *b, size_t ldb,
                            float beta, float *c, size_t ldc) {
    for (size_t i = 0; i < m; i++) {
        for (size_t j = 0; j < n; j++) {
            float sum = 0.0f;
            for (size_t p = 0; p < k; p++) {
                const float av = trans_a ? a[p * lda + i] : a[i * lda + p];
                const float bv = trans_b ? b[j * ldb + p] : b[p * ldb + j];
                sum += av * bv;
            }
            c[i * ldc + j] = beta == 0.0f ? sum : c[i * ldc + j] + sum;
        }
    }
}

void wax_mil_sgemm(int trans_a, int trans_b,
                   size_t m, size_t n, size_t k,
                   const float *a, size_t lda,
                   const float *b, size_t ldb,
                   float beta,
                   float *c, size_t ldc) {
    if (m == 0 || n == 0) return;
    if (k == 0) {
        if (beta == 0.0f) {
            for (size_t i = 0; i < m; i++) memset(c + i * ldc, 0, n * sizeof(float));
        }
        return;
    }

    const size_t kc_max = k < WAX_KC ? k : WAX_KC;
    const size_t mc_max = m < WAX_MC ? m : WAX_MC;
    const size_t nc_max = n < WAX_NC ? n : WAX_NC;
    const size_t mc_padded = (mc_max + WAX_MR - 1) / WAX_MR * WAX_MR;
    const size_t nc_padded = (nc_max + WAX_NR - 1) / WAX_NR * WAX_NR;
    float *ap = wax_aligned_alloc(mc_padded * kc_max * sizeof(float));
    float *bp = wax_aligned_alloc(nc_padded * kc_max * sizeof(float));
    if (ap == NULL || bp == NULL) {
        free(ap);
        free(bp);
        wax_sgemm_naive(trans_a, trans_b, m, n, k, a, lda, b, ldb, beta, c, ldc);
        return;
    }

#if WAX_X86_DISPATCH
    const int avx2 = wax_use_avx2();
#endif

    for (size_t j0 = 0; j0 < n; j0 += WAX_NC) {
        const size_t nc = (n - j0) < WAX_NC ? (n - j0) : WAX_NC;
        for (size_t p0 = 0; p0 < k; p0 += WAX_KC) {
            const size_t kc = (k - p0) < WAX_KC ? (k - p0) : WAX_KC;
            const int accumulate = p0 > 0 || beta != 0.0f;
            wax_pack_b(trans_b, b, ldb, p0, kc, j0, nc, bp);
            for (size_t i0 = 0; i0 < m; i0 += WAX_MC) {
                const size_t mc = (m - i0) < WAX_MC ? (m - i0) : WAX_MC;
                wax_pack_a(trans_a, a, lda, i0, mc, p0, kc, ap);
                float *cblock = c + i0 * ldc + j0;
#if WAX_X86_DISPATCH
                if (avx2) {
                    wax_macro_kernel_avx2(mc, nc, kc, ap, bp, cblock, ldc, accumulate);
                    continue;
                }
#endif
                wax_macro_kernel_generic(mc, nc, kc, ap, bp, cblock, ldc, accumulate);
            }
        }
    }
    free(ap);
    free(bp);
}

// Packed-B layout: for each NC-wide column block j0, for each KC-deep row block p0, the
// kc x round_up(nc, NR) panels that wax_pack_b produces. The block for (j0, p0) starts at
// j0 * k + p0 * round_up(nc, NR) floats (every earlier column block is a full NC wide).
static size_t wax_round_up_nr(size_t value) {
    return (value + WAX_NR - 1) / WAX_NR * WAX_NR;
}

size_t wax_mil_sgemm_packed_b_count(size_t n, size_t k) {
    size_t total = 0;
    for (size_t j0 = 0; j0 < n; j0 += WAX_NC) {
        const size_t nc = (n - j0) < WAX_NC ? (n - j0) : WAX_NC;
        total += wax_round_up_nr(nc) * k;
    }
    return total;
}

void wax_mil_sgemm_pack_b(int trans_b, size_t n, size_t k, const float *b, size_t ldb, float *packed) {
    for (size_t j0 = 0; j0 < n; j0 += WAX_NC) {
        const size_t nc = (n - j0) < WAX_NC ? (n - j0) : WAX_NC;
        for (size_t p0 = 0; p0 < k; p0 += WAX_KC) {
            const size_t kc = (k - p0) < WAX_KC ? (k - p0) : WAX_KC;
            wax_pack_b(trans_b, b, ldb, p0, kc, j0, nc, packed + j0 * k + p0 * wax_round_up_nr(nc));
        }
    }
}

void wax_mil_sgemm_packed(int trans_a,
                          size_t m, size_t n, size_t k,
                          const float *a, size_t lda,
                          const float *packed_b,
                          size_t j_begin, size_t j_end,
                          float beta,
                          float *c, size_t ldc) {
    if (j_end > n) j_end = n;
    j_begin = j_begin / WAX_NR * WAX_NR;
    if (m == 0 || j_begin >= j_end) return;
    if (k == 0) {
        if (beta == 0.0f) {
            for (size_t i = 0; i < m; i++) memset(c + i * ldc + j_begin, 0, (j_end - j_begin) * sizeof(float));
        }
        return;
    }
    const size_t kc_max = k < WAX_KC ? k : WAX_KC;
    const size_t mc_max = m < WAX_MC ? m : WAX_MC;
    const size_t mc_padded = (mc_max + WAX_MR - 1) / WAX_MR * WAX_MR;
    float *ap = wax_aligned_alloc(mc_padded * kc_max * sizeof(float));
    if (ap == NULL) {
        // Out of memory for a 96 KB panel: compute each element straight from the packed panels.
        for (size_t i = 0; i < m; i++) {
            for (size_t j = j_begin; j < j_end; j++) {
                const size_t j0 = j / WAX_NC * WAX_NC;
                const size_t nc = (n - j0) < WAX_NC ? (n - j0) : WAX_NC;
                float sum = 0.0f;
                for (size_t p = 0; p < k; p++) {
                    const size_t p0 = p / WAX_KC * WAX_KC;
                    const size_t kc = (k - p0) < WAX_KC ? (k - p0) : WAX_KC;
                    const float *block = packed_b + j0 * k + p0 * wax_round_up_nr(nc);
                    const size_t jr = (j - j0) / WAX_NR;
                    const float bv = block[jr * kc * WAX_NR + (p - p0) * WAX_NR + (j - j0) % WAX_NR];
                    sum += (trans_a ? a[p * lda + i] : a[i * lda + p]) * bv;
                }
                c[i * ldc + j] = beta == 0.0f ? sum : c[i * ldc + j] + sum;
            }
        }
        return;
    }
#if WAX_X86_DISPATCH
    const int avx2 = wax_use_avx2();
#endif
    for (size_t p0 = 0; p0 < k; p0 += WAX_KC) {
        const size_t kc = (k - p0) < WAX_KC ? (k - p0) : WAX_KC;
        const int accumulate = p0 > 0 || beta != 0.0f;
        for (size_t i0 = 0; i0 < m; i0 += WAX_MC) {
            const size_t mc = (m - i0) < WAX_MC ? (m - i0) : WAX_MC;
            wax_pack_a(trans_a, a, lda, i0, mc, p0, kc, ap);
            for (size_t j0 = j_begin / WAX_NC * WAX_NC; j0 < j_end; j0 += WAX_NC) {
                const size_t nc = (n - j0) < WAX_NC ? (n - j0) : WAX_NC;
                const size_t lo = j_begin > j0 ? j_begin : j0;
                const size_t hi = (j0 + nc) < j_end ? (j0 + nc) : j_end;
                const float *bp = packed_b + j0 * k + p0 * wax_round_up_nr(nc) + ((lo - j0) / WAX_NR) * kc * WAX_NR;
                float *cblock = c + i0 * ldc + lo;
#if WAX_X86_DISPATCH
                if (avx2) {
                    wax_macro_kernel_avx2(mc, hi - lo, kc, ap, bp, cblock, ldc, accumulate);
                    continue;
                }
#endif
                wax_macro_kernel_generic(mc, hi - lo, kc, ap, bp, cblock, ldc, accumulate);
            }
        }
    }
    free(ap);
}

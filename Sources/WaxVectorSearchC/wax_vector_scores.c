#include "wax_vector_scores.h"

#include <string.h>

// Multiplies and adds stay separate unless a kernel asks for a fused multiply-add
// explicitly, so each kernel's rounding is fixed by its source, not by the optimizer.
#pragma STDC FP_CONTRACT OFF

#if defined(__x86_64__) && (defined(__clang__) || defined(__GNUC__))
#include <cpuid.h>
#include <immintrin.h>
#define WAX_VS_X86_DISPATCH 1
#else
#define WAX_VS_X86_DISPATCH 0
#endif

// The 8-float vector type and run-time AVX2 dispatch follow WaxMILKernelsC/wax_mil_sgemm.c.
typedef float v8f __attribute__((vector_size(32)));

// An unaligned load. A macro, not a function: a function returning a 32-byte vector has a
// different calling convention in the generic and AVX2 variants.
#define WAX_LOAD8(p) ({ v8f wax_loaded_; memcpy(&wax_loaded_, (p), sizeof(wax_loaded_)); wax_loaded_; })

#define WAX_VS_NAME wax_vector_scores_generic
#define WAX_VS_FINISH wax_vector_finish_generic
#define WAX_VS_ATTR
#define WAX_VS_MADD(acc, a, b) ((acc) + (a) * (b))
#include "wax_vector_scores_kernel.h"
#undef WAX_VS_NAME
#undef WAX_VS_FINISH
#undef WAX_VS_ATTR
#undef WAX_VS_MADD

#if WAX_VS_X86_DISPATCH
#define WAX_VS_NAME wax_vector_scores_avx2
#define WAX_VS_FINISH wax_vector_finish_avx2
#define WAX_VS_ATTR __attribute__((target("avx2,fma")))
#define WAX_VS_MADD(acc, a, b) ((v8f)_mm256_fmadd_ps((__m256)(a), (__m256)(b), (__m256)(acc)))
#include "wax_vector_scores_kernel.h"
#undef WAX_VS_NAME
#undef WAX_VS_FINISH
#undef WAX_VS_ATTR
#undef WAX_VS_MADD

// Same check as WaxMILKernelsC: CPUID AVX, FMA and AVX2, and the OS saving YMM state.
static int wax_vs_detect_avx2_fma(void) {
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

// 0 = not yet detected, else the WAX_VECTOR_KERNEL_* AUTO resolves to. Racing first calls
// compute the same value.
static int32_t wax_vs_best_kernel = 0;

static int32_t wax_vs_best(void) {
    int32_t best = __atomic_load_n(&wax_vs_best_kernel, __ATOMIC_RELAXED);
    if (best == 0) {
        best = wax_vs_detect_avx2_fma() ? WAX_VECTOR_KERNEL_AVX2 : WAX_VECTOR_KERNEL_GENERIC;
        __atomic_store_n(&wax_vs_best_kernel, best, __ATOMIC_RELAXED);
    }
    return best;
}
#endif

int32_t wax_vector_kernel_resolve(int32_t requested) {
#if WAX_VS_X86_DISPATCH
    const int32_t best = wax_vs_best();
    if (requested == WAX_VECTOR_KERNEL_AUTO) return best;
    if (requested == WAX_VECTOR_KERNEL_AVX2 && best == WAX_VECTOR_KERNEL_AVX2) return WAX_VECTOR_KERNEL_AVX2;
#else
    (void)requested;
#endif
    return WAX_VECTOR_KERNEL_GENERIC;
}

void wax_vector_scores(
    int32_t kernel,
    const float *rows,
    int64_t row_count,
    int64_t dim,
    const float *query,
    const float *squared_norms,
    float query_norm,
    float *scores
) {
    if (row_count <= 0) return;
#if WAX_VS_X86_DISPATCH
    if (wax_vector_kernel_resolve(kernel) == WAX_VECTOR_KERNEL_AVX2) {
        wax_vector_scores_avx2(rows, row_count, dim, query, squared_norms, query_norm, scores);
        return;
    }
#else
    (void)kernel;
#endif
    wax_vector_scores_generic(rows, row_count, dim, query, squared_norms, query_norm, scores);
}

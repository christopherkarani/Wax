// Macro-kernel body, included once per instruction-set variant by wax_mil_sgemm.c with
// WAX_KERNEL_NAME and WAX_KERNEL_ATTR defined. Not a public header.
//
// Multiplies packed panels: `ap` holds ceil(mc / MR) panels of MR rows x kc, k-major;
// `bp` holds ceil(nc / NR) panels of kc x NR columns, k-major. Writes (or, when
// `accumulate` is set, adds) the mc x nc block into C. The 6 x 16 register tile uses GCC/Clang
// vector extensions, which lower to AVX2/FMA, SSE or NEON as the variant's target allows.

static WAX_KERNEL_ATTR void WAX_KERNEL_NAME(size_t mc, size_t nc, size_t kc,
                                            const float *restrict ap, const float *restrict bp,
                                            float *restrict c, size_t ldc, int accumulate) {
    for (size_t jr = 0; jr < nc; jr += WAX_NR) {
        const size_t nr = (nc - jr) < WAX_NR ? (nc - jr) : WAX_NR;
        const float *bpanel = bp + (jr / WAX_NR) * kc * WAX_NR;
        for (size_t ir = 0; ir < mc; ir += WAX_MR) {
            const size_t mr = (mc - ir) < WAX_MR ? (mc - ir) : WAX_MR;
            const float *apanel = ap + (ir / WAX_MR) * kc * WAX_MR;
            const v8f zero = {0, 0, 0, 0, 0, 0, 0, 0};
            v8f c00 = zero, c01 = zero, c10 = zero, c11 = zero, c20 = zero, c21 = zero;
            v8f c30 = zero, c31 = zero, c40 = zero, c41 = zero, c50 = zero, c51 = zero;
            const float *a = apanel;
            const float *b = bpanel;
            for (size_t p = 0; p < kc; p++) {
                const v8f b0 = *(const v8f *)(b);
                const v8f b1 = *(const v8f *)(b + 8);
                v8f s;
                s = wax_splat(a[0]); c00 += s * b0; c01 += s * b1;
                s = wax_splat(a[1]); c10 += s * b0; c11 += s * b1;
                s = wax_splat(a[2]); c20 += s * b0; c21 += s * b1;
                s = wax_splat(a[3]); c30 += s * b0; c31 += s * b1;
                s = wax_splat(a[4]); c40 += s * b0; c41 += s * b1;
                s = wax_splat(a[5]); c50 += s * b0; c51 += s * b1;
                a += WAX_MR;
                b += WAX_NR;
            }
            float *cblock = c + ir * ldc + jr;
            if (mr == WAX_MR && nr == WAX_NR) {
                v8f rows[WAX_MR][2] = {{c00, c01}, {c10, c11}, {c20, c21}, {c30, c31}, {c40, c41}, {c50, c51}};
                for (size_t i = 0; i < WAX_MR; i++) {
                    float *row = cblock + i * ldc;
                    if (accumulate) {
                        v8f old0, old1;
                        memcpy(&old0, row, sizeof(v8f));
                        memcpy(&old1, row + 8, sizeof(v8f));
                        rows[i][0] += old0;
                        rows[i][1] += old1;
                    }
                    memcpy(row, &rows[i][0], sizeof(v8f));
                    memcpy(row + 8, &rows[i][1], sizeof(v8f));
                }
            } else {
                float tile[WAX_MR][WAX_NR] __attribute__((aligned(32)));
                memcpy(&tile[0][0], &c00, sizeof(v8f)); memcpy(&tile[0][8], &c01, sizeof(v8f));
                memcpy(&tile[1][0], &c10, sizeof(v8f)); memcpy(&tile[1][8], &c11, sizeof(v8f));
                memcpy(&tile[2][0], &c20, sizeof(v8f)); memcpy(&tile[2][8], &c21, sizeof(v8f));
                memcpy(&tile[3][0], &c30, sizeof(v8f)); memcpy(&tile[3][8], &c31, sizeof(v8f));
                memcpy(&tile[4][0], &c40, sizeof(v8f)); memcpy(&tile[4][8], &c41, sizeof(v8f));
                memcpy(&tile[5][0], &c50, sizeof(v8f)); memcpy(&tile[5][8], &c51, sizeof(v8f));
                for (size_t i = 0; i < mr; i++) {
                    float *row = cblock + i * ldc;
                    if (accumulate) {
                        for (size_t j = 0; j < nr; j++) row[j] += tile[i][j];
                    } else {
                        for (size_t j = 0; j < nr; j++) row[j] = tile[i][j];
                    }
                }
            }
        }
    }
}

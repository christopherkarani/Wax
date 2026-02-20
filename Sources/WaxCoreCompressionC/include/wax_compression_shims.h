#ifndef WAX_COMPRESSION_SHIMS_H
#define WAX_COMPRESSION_SHIMS_H

#include <stddef.h>
#include <stdint.h>

int32_t wax_lz4_compress(
    const uint8_t *src,
    size_t src_len,
    uint8_t *dst,
    size_t dst_cap,
    size_t *out_len
);

int32_t wax_lz4_decompress(
    const uint8_t *src,
    size_t src_len,
    uint8_t *dst,
    size_t dst_len
);

int32_t wax_deflate_compress(
    const uint8_t *src,
    size_t src_len,
    uint8_t *dst,
    size_t *inout_dst_len
);

int32_t wax_deflate_decompress(
    const uint8_t *src,
    size_t src_len,
    uint8_t *dst,
    size_t *inout_dst_len
);

#endif

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

/// Decodes Apple `COMPRESSION_LZ4` output: a sequence of `bv41` (LZ4 block) and
/// `bv4-` (stored) blocks terminated by `bv4$`. Blocks may reference up to 64 KiB of
/// previously decoded output. Returns 0 only when exactly `dst_len` bytes decode.
int32_t wax_lz4_decompress_apple_framed(
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

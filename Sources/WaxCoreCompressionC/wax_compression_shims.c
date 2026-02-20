#include "wax_compression_shims.h"

#include <lz4.h>
#include <zlib.h>

int32_t wax_lz4_compress(
    const uint8_t *src,
    size_t src_len,
    uint8_t *dst,
    size_t dst_cap,
    size_t *out_len
) {
    if (src == NULL || dst == NULL || out_len == NULL) {
        return -1;
    }
    if (src_len > (size_t)INT32_MAX || dst_cap > (size_t)INT32_MAX) {
        return -2;
    }

    const int bound = LZ4_compressBound((int)src_len);
    if (bound <= 0) {
        return -3;
    }
    if ((size_t)bound > dst_cap) {
        return -4;
    }

    const int written = LZ4_compress_default(
        (const char *)src,
        (char *)dst,
        (int)src_len,
        (int)dst_cap
    );
    if (written <= 0) {
        return -5;
    }
    *out_len = (size_t)written;
    return 0;
}

int32_t wax_lz4_decompress(
    const uint8_t *src,
    size_t src_len,
    uint8_t *dst,
    size_t dst_len
) {
    if (src == NULL || dst == NULL) {
        return -1;
    }
    if (src_len > (size_t)INT32_MAX || dst_len > (size_t)INT32_MAX) {
        return -2;
    }

    const int written = LZ4_decompress_safe(
        (const char *)src,
        (char *)dst,
        (int)src_len,
        (int)dst_len
    );
    if (written < 0) {
        return -3;
    }
    if ((size_t)written != dst_len) {
        return -4;
    }
    return 0;
}

int32_t wax_deflate_compress(
    const uint8_t *src,
    size_t src_len,
    uint8_t *dst,
    size_t *inout_dst_len
) {
    if (src == NULL || dst == NULL || inout_dst_len == NULL) {
        return -1;
    }
    if (src_len > (size_t)UINT32_MAX || *inout_dst_len > (size_t)UINT32_MAX) {
        return -2;
    }

    uLongf out_len = (uLongf)(*inout_dst_len);
    const int zrc = compress2(
        dst,
        &out_len,
        src,
        (uLong)src_len,
        Z_DEFAULT_COMPRESSION
    );
    if (zrc != Z_OK) {
        return -3;
    }
    *inout_dst_len = (size_t)out_len;
    return 0;
}

int32_t wax_deflate_decompress(
    const uint8_t *src,
    size_t src_len,
    uint8_t *dst,
    size_t *inout_dst_len
) {
    if (src == NULL || dst == NULL || inout_dst_len == NULL) {
        return -1;
    }
    if (src_len > (size_t)UINT32_MAX || *inout_dst_len > (size_t)UINT32_MAX) {
        return -2;
    }

    uLongf out_len = (uLongf)(*inout_dst_len);
    const int zrc = uncompress(
        dst,
        &out_len,
        src,
        (uLong)src_len
    );
    if (zrc != Z_OK) {
        return -3;
    }
    *inout_dst_len = (size_t)out_len;
    return 0;
}

#include "wax_compression_shims.h"

#include <lz4.h>
#include <string.h>
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

static uint32_t wax_read_le32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

int32_t wax_lz4_decompress_apple_framed(
    const uint8_t *src,
    size_t src_len,
    uint8_t *dst,
    size_t dst_len
) {
    if (src == NULL || dst == NULL) {
        return -1;
    }
    if (dst_len > (size_t)INT32_MAX) {
        return -2;
    }

    const size_t history_limit = 64 * 1024;
    size_t in = 0;
    size_t out = 0;
    for (;;) {
        if (src_len - in < 4) {
            return -3; // missing end marker
        }
        const uint8_t *magic = src + in;
        if (memcmp(magic, "bv4$", 4) == 0) {
            return (in + 4 == src_len && out == dst_len) ? 0 : -4;
        }
        if (src_len - in < 8) {
            return -3;
        }
        const size_t raw_len = wax_read_le32(src + in + 4);
        if (raw_len > dst_len - out) {
            return -4;
        }
        if (memcmp(magic, "bv4-", 4) == 0) {
            in += 8;
            if (raw_len > src_len - in) {
                return -3;
            }
            memcpy(dst + out, src + in, raw_len);
            in += raw_len;
            out += raw_len;
            continue;
        }
        if (memcmp(magic, "bv41", 4) != 0 || src_len - in < 12) {
            return -5;
        }
        const size_t enc_len = wax_read_le32(src + in + 8);
        in += 12;
        if (enc_len > src_len - in || enc_len > (size_t)INT32_MAX) {
            return -3;
        }
        const size_t dict_len = out < history_limit ? out : history_limit;
        const int written = LZ4_decompress_safe_usingDict(
            (const char *)(src + in),
            (char *)(dst + out),
            (int)enc_len,
            (int)raw_len,
            (const char *)(dst + out - dict_len),
            (int)dict_len
        );
        if (written < 0 || (size_t)written != raw_len) {
            return -6;
        }
        in += enc_len;
        out += raw_len;
    }
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
    if (zrc == Z_DATA_ERROR) {
        // Fallback for raw DEFLATE payloads (no zlib wrapper) produced by
        // some platform codecs for "deflate"/zlib algorithm selections.
        z_stream stream;
        memset(&stream, 0, sizeof(stream));
        stream.next_in = (Bytef *)src;
        stream.avail_in = (uInt)src_len;
        stream.next_out = dst;
        stream.avail_out = (uInt)(*inout_dst_len);

        if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) {
            return -3;
        }
        const int raw_rc = inflate(&stream, Z_FINISH);
        const int end_rc = inflateEnd(&stream);
        if (raw_rc == Z_STREAM_END && end_rc == Z_OK) {
            *inout_dst_len = (size_t)stream.total_out;
            return 0;
        }
        return -3;
    }
    if (zrc != Z_OK) {
        return -3;
    }
    *inout_dst_len = (size_t)out_len;
    return 0;
}

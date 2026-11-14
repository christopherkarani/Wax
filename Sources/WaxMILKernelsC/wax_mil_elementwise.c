#include "wax_mil_kernels.h"

#include <math.h>
#include <string.h>

static inline float wax_half_to_float(uint16_t h) {
    const uint32_t sign = (uint32_t)(h & 0x8000u) << 16;
    const uint32_t exponent = (h >> 10) & 0x1Fu;
    uint32_t mantissa = h & 0x3FFu;
    uint32_t bits;
    if (exponent == 0) {
        if (mantissa == 0) {
            bits = sign;
        } else {
            // Subnormal: renormalise.
            int e = -1;
            do {
                e++;
                mantissa <<= 1;
            } while ((mantissa & 0x400u) == 0);
            bits = sign | ((uint32_t)(127 - 15 - e) << 23) | ((mantissa & 0x3FFu) << 13);
        }
    } else if (exponent == 0x1F) {
        bits = sign | 0x7F800000u | (mantissa << 13);
    } else {
        bits = sign | ((exponent + (127 - 15)) << 23) | (mantissa << 13);
    }
    float value;
    memcpy(&value, &bits, sizeof value);
    return value;
}

void wax_mil_f16_to_f32(const uint16_t *src, float *dst, size_t count) {
    for (size_t i = 0; i < count; i++) dst[i] = wax_half_to_float(src[i]);
}

void wax_mil_i8_to_f32(const int8_t *src, float *dst, size_t count) {
    for (size_t i = 0; i < count; i++) dst[i] = (float)src[i];
}

void wax_mil_u8_to_f32(const uint8_t *src, float *dst, size_t count) {
    for (size_t i = 0; i < count; i++) dst[i] = (float)src[i];
}

void wax_mil_blockwise_dequantize(float *values, size_t rank, const size_t *shape,
                                  const float *scale, const float *offset,
                                  const size_t *scale_shape) {
    if (rank == 0 || rank > 8) return;
    size_t block[8];
    size_t total = 1;
    for (size_t d = 0; d < rank; d++) {
        block[d] = shape[d] / scale_shape[d];
        total *= shape[d];
    }
    if (total == 0) return;
    const size_t last = rank - 1;
    const size_t cols = shape[last];
    const size_t rows = total / cols;
    size_t index[8] = {0};
    for (size_t r = 0; r < rows; r++) {
        // Scale index of the row's first element, from the coordinates of the leading axes.
        size_t base = 0;
        for (size_t d = 0; d < last; d++) base = base * scale_shape[d] + index[d] / block[d];
        base *= scale_shape[last];
        float *row = values + r * cols;
        const size_t width = block[last];
        for (size_t j0 = 0, s = base; j0 < cols; j0 += width, s++) {
            const float sc = scale[s];
            const float off = offset ? offset[s] : 0.0f;
            for (size_t j = j0; j < j0 + width; j++) row[j] = (row[j] - off) * sc;
        }
        // Advance the leading-axis coordinates.
        for (size_t d = last; d-- > 0;) {
            if (++index[d] < shape[d]) break;
            index[d] = 0;
        }
    }
}

void wax_mil_layer_norm(const float *x, float *y, size_t rows, size_t cols,
                        const float *gamma, const float *beta, float epsilon) {
    if (cols == 0) return;
    for (size_t r = 0; r < rows; r++) {
        const float *in = x + r * cols;
        float *out = y + r * cols;
        // Two passes in single precision: mean, then variance about the mean.
        float mean = 0.0f;
        for (size_t j = 0; j < cols; j++) mean += in[j];
        mean /= (float)cols;
        float variance = 0.0f;
        for (size_t j = 0; j < cols; j++) {
            const float d = in[j] - mean;
            variance += d * d;
        }
        variance /= (float)cols;
        const float inv = 1.0f / sqrtf(variance + epsilon);
        for (size_t j = 0; j < cols; j++) {
            float v = (in[j] - mean) * inv;
            if (gamma) v *= gamma[j];
            if (beta) v += beta[j];
            out[j] = v;
        }
    }
}

void wax_mil_softmax(const float *x, float *y, size_t outer, size_t length, size_t inner) {
    if (length == 0) return;
    for (size_t o = 0; o < outer; o++) {
        const float *in = x + o * length * inner;
        float *out = y + o * length * inner;
        if (inner == 1) {
            float maximum = in[0];
            for (size_t j = 1; j < length; j++) maximum = in[j] > maximum ? in[j] : maximum;
            float sum = 0.0f;
            for (size_t j = 0; j < length; j++) {
                const float e = expf(in[j] - maximum);
                out[j] = e;
                sum += e;
            }
            const float inv = 1.0f / sum;
            for (size_t j = 0; j < length; j++) out[j] *= inv;
            continue;
        }
        for (size_t i = 0; i < inner; i++) {
            float maximum = in[i];
            for (size_t j = 1; j < length; j++) {
                const float v = in[j * inner + i];
                maximum = v > maximum ? v : maximum;
            }
            float sum = 0.0f;
            for (size_t j = 0; j < length; j++) {
                const float e = expf(in[j * inner + i] - maximum);
                out[j * inner + i] = e;
                sum += e;
            }
            const float inv = 1.0f / sum;
            for (size_t j = 0; j < length; j++) out[j * inner + i] *= inv;
        }
    }
}

void wax_mil_gelu(const float *x, float *y, size_t count, int mode) {
    switch (mode) {
    case 0: {
        const float inv_sqrt2 = 0.70710678118654752440f;
        for (size_t i = 0; i < count; i++) y[i] = 0.5f * x[i] * (1.0f + erff(x[i] * inv_sqrt2));
        break;
    }
    case 1: {
        const float k = 0.79788456080286535588f; // sqrt(2 / pi)
        for (size_t i = 0; i < count; i++) {
            const float v = x[i];
            y[i] = 0.5f * v * (1.0f + tanhf(k * (v + 0.044715f * v * v * v)));
        }
        break;
    }
    default:
        for (size_t i = 0; i < count; i++) y[i] = x[i] / (1.0f + expf(-1.702f * x[i]));
        break;
    }
}

void wax_mil_tanh(const float *x, float *y, size_t count) {
    for (size_t i = 0; i < count; i++) y[i] = tanhf(x[i]);
}

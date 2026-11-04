// scrypt, straight from RFC 7914. PBKDF2-HMAC-SHA256 comes from CommonCrypto;
// the ROMix/BlockMix/Salsa20-8 middle is written out here.
//
// Little-endian only (arm64/x86_64): Integerify and the Salsa core read the
// 64-byte blocks as host-order uint32 words directly.

#include "include/fcxl_scrypt.h"

#include <CommonCrypto/CommonCrypto.h>
#include <CommonCrypto/CommonKeyDerivation.h>
#include <stdlib.h>
#include <string.h>

static void salsa20_8(uint32_t b[16]) {
    uint32_t x[16];
    memcpy(x, b, 64);
#define R(a, k) (((a) << (k)) | ((a) >> (32 - (k))))
    for (int i = 0; i < 8; i += 2) {
        x[4] ^= R(x[0] + x[12], 7);
        x[8] ^= R(x[4] + x[0], 9);
        x[12] ^= R(x[8] + x[4], 13);
        x[0] ^= R(x[12] + x[8], 18);
        x[9] ^= R(x[5] + x[1], 7);
        x[13] ^= R(x[9] + x[5], 9);
        x[1] ^= R(x[13] + x[9], 13);
        x[5] ^= R(x[1] + x[13], 18);
        x[14] ^= R(x[10] + x[6], 7);
        x[2] ^= R(x[14] + x[10], 9);
        x[6] ^= R(x[2] + x[14], 13);
        x[10] ^= R(x[6] + x[2], 18);
        x[3] ^= R(x[15] + x[11], 7);
        x[7] ^= R(x[3] + x[15], 9);
        x[11] ^= R(x[7] + x[3], 13);
        x[15] ^= R(x[11] + x[7], 18);
        x[1] ^= R(x[0] + x[3], 7);
        x[2] ^= R(x[1] + x[0], 9);
        x[3] ^= R(x[2] + x[1], 13);
        x[0] ^= R(x[3] + x[2], 18);
        x[6] ^= R(x[5] + x[4], 7);
        x[7] ^= R(x[6] + x[5], 9);
        x[4] ^= R(x[7] + x[6], 13);
        x[5] ^= R(x[4] + x[7], 18);
        x[11] ^= R(x[10] + x[9], 7);
        x[8] ^= R(x[11] + x[10], 9);
        x[9] ^= R(x[8] + x[11], 13);
        x[10] ^= R(x[9] + x[8], 18);
        x[12] ^= R(x[15] + x[14], 7);
        x[13] ^= R(x[12] + x[15], 9);
        x[14] ^= R(x[13] + x[12], 13);
        x[15] ^= R(x[14] + x[13], 18);
    }
#undef R
    for (int i = 0; i < 16; i++) b[i] += x[i];
}

/// BlockMix: `in` and `out` are 2r blocks of 64 bytes (32r words) each.
/// Output order per the RFC: even-indexed results first, then odd.
static void blockmix(const uint32_t *in, uint32_t *out, uint32_t r) {
    uint32_t x[16];
    memcpy(x, &in[(2 * r - 1) * 16], 64);
    for (uint32_t i = 0; i < 2 * r; i++) {
        for (int j = 0; j < 16; j++) x[j] ^= in[i * 16 + j];
        salsa20_8(x);
        memcpy(&out[((i / 2) + (i & 1) * r) * 16], x, 64);
    }
}

static int romix(uint32_t *block, uint64_t n, uint32_t r) {
    const size_t words = 32 * (size_t)r; /* one 128r-byte block in uint32s */
    uint32_t *v = malloc((size_t)n * words * 4);
    uint32_t *x = malloc(words * 4);
    uint32_t *y = malloc(words * 4);
    if (!v || !x || !y) {
        free(v);
        free(x);
        free(y);
        return -1;
    }
    memcpy(x, block, words * 4);
    for (uint64_t i = 0; i < n; i++) {
        memcpy(&v[i * words], x, words * 4);
        blockmix(x, y, r);
        uint32_t *t = x;
        x = y;
        y = t;
    }
    for (uint64_t i = 0; i < n; i++) {
        /* Integerify: the last 64-byte sub-block as a little-endian integer */
        uint64_t j = (x[(2 * r - 1) * 16] |
                      ((uint64_t)x[(2 * r - 1) * 16 + 1] << 32)) & (n - 1);
        const uint32_t *vj = &v[j * words];
        for (size_t k = 0; k < words; k++) x[k] ^= vj[k];
        blockmix(x, y, r);
        uint32_t *t = x;
        x = y;
        y = t;
    }
    memcpy(block, x, words * 4);
    free(v);
    free(x);
    free(y);
    return 0;
}

int fcxl_scrypt(const uint8_t *password, size_t password_len,
                const uint8_t *salt, size_t salt_len,
                uint64_t n, uint32_t r, uint32_t p,
                uint8_t *out, size_t out_len) {
    if (n < 2 || (n & (n - 1)) != 0 || r == 0 || p == 0 || out_len == 0) return -1;
    /* Guard the multiplications the RFC guards: 128*r*p and 128*r*N must fit. */
    if ((uint64_t)r * p >= (1u << 30) || n > (1ull << 48) / (128ull * r)) return -1;

    const size_t block_bytes = 128 * (size_t)r;
    uint8_t *b = malloc((size_t)p * block_bytes);
    if (!b) return -1;

    /* Empty password/salt still need non-NULL pointers for CommonCrypto. */
    static const uint8_t nothing = 0;
    const char *pw = (const char *)(password_len ? password : &nothing);
    const uint8_t *st = salt_len ? salt : &nothing;

    if (CCKeyDerivationPBKDF(kCCPBKDF2, pw, password_len, st, salt_len,
                             kCCPRFHmacAlgSHA256, 1,
                             b, (size_t)p * block_bytes) != kCCSuccess) {
        free(b);
        return -1;
    }
    for (uint32_t i = 0; i < p; i++) {
        if (romix((uint32_t *)(b + (size_t)i * block_bytes), n, r) != 0) {
            free(b);
            return -1;
        }
    }
    int rc = CCKeyDerivationPBKDF(kCCPBKDF2, pw, password_len,
                                  b, (size_t)p * block_bytes,
                                  kCCPRFHmacAlgSHA256, 1,
                                  out, out_len) == kCCSuccess ? 0 : -1;
    memset(b, 0, (size_t)p * block_bytes);
    free(b);
    return rc;
}

#ifndef FCXL_SCRYPT_H
#define FCXL_SCRYPT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// scrypt (RFC 7914). Returns 0 on success, -1 on bad parameters or allocation
/// failure. `n` must be a power of two greater than 1.
///
/// Lives in its own C target so the key derivation runs at -O2 even in debug
/// builds of the app: the Salsa20/8 core inside is pure arithmetic, and an
/// unoptimised Swift or -O0 build would turn a one-second derivation into
/// a coffee break.
int fcxl_scrypt(const uint8_t *password, size_t password_len,
                const uint8_t *salt, size_t salt_len,
                uint64_t n, uint32_t r, uint32_t p,
                uint8_t *out, size_t out_len);

#ifdef __cplusplus
}
#endif

#endif

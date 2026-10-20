// zlib streams and the Diffie-Hellman agreement used by the VNC client.

#include "AfarEngine.h"

#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#include <openssl/bn.h>
#include <openssl/rand.h>

// MARK: - zlib

struct AfarInflater {
    z_stream z;
    uint8_t *buffer;
    size_t capacity;
};

AfarInflater *afar_inflater_new(void) {
    AfarInflater *inflater = calloc(1, sizeof(*inflater));
    if (!inflater)
        return NULL;
    if (inflateInit(&inflater->z) != Z_OK) {
        free(inflater);
        return NULL;
    }
    return inflater;
}

void afar_inflater_free(AfarInflater *inflater) {
    if (!inflater)
        return;
    inflateEnd(&inflater->z);
    free(inflater->buffer);
    free(inflater);
}

void afar_inflater_reset(AfarInflater *inflater) {
    if (inflater)
        inflateReset(&inflater->z);
}

const uint8_t *afar_inflate(AfarInflater *inflater, const uint8_t *input, size_t length, size_t *outputLength) {
    if (!inflater || !outputLength)
        return NULL;
    inflater->z.next_in = (Bytef *)input;
    inflater->z.avail_in = (uInt)length;
    size_t produced = 0;
    do {
        if (inflater->capacity - produced < 65536) {
            const size_t capacity = inflater->capacity ? inflater->capacity * 2 : 262144;
            uint8_t *grown = realloc(inflater->buffer, capacity);
            if (!grown)
                return NULL;
            inflater->buffer = grown;
            inflater->capacity = capacity;
        }
        inflater->z.next_out = inflater->buffer + produced;
        inflater->z.avail_out = (uInt)(inflater->capacity - produced);
        const int result = inflate(&inflater->z, Z_SYNC_FLUSH);
        produced = inflater->capacity - inflater->z.avail_out;
        if (result != Z_OK && result != Z_BUF_ERROR && result != Z_STREAM_END)
            return NULL;
        if (result == Z_BUF_ERROR && inflater->z.avail_in == 0)
            break;
    } while (inflater->z.avail_in > 0 || inflater->z.avail_out == 0);
    *outputLength = produced;
    return inflater->buffer;
}

uint8_t *afar_deflate(const uint8_t *input, size_t length, size_t *outputLength) {
    uLongf bound = compressBound((uLong)length);
    uint8_t *output = malloc(bound);
    if (!output)
        return NULL;
    if (compress2(output, &bound, input, (uLong)length, Z_DEFAULT_COMPRESSION) != Z_OK) {
        free(output);
        return NULL;
    }
    *outputLength = bound;
    return output;
}

// MARK: - Diffie-Hellman

bool afar_dh_agree(const uint8_t *generator, size_t generatorLength, const uint8_t *prime,
                   const uint8_t *serverPublic, size_t length, uint8_t *clientPublic, uint8_t *secret) {
    BN_CTX *context = BN_CTX_new();
    BIGNUM *g = BN_bin2bn(generator, (int)generatorLength, NULL);
    BIGNUM *p = BN_bin2bn(prime, (int)length, NULL);
    BIGNUM *server = BN_bin2bn(serverPublic, (int)length, NULL);
    BIGNUM *private = BN_new(), *public = BN_new(), *shared = BN_new();
    bool ok = context && g && p && server && private && public && shared &&
              BN_rand_range(private, p) &&
              BN_mod_exp(public, g, private, p, context) &&
              BN_mod_exp(shared, server, private, p, context) &&
              BN_bn2binpad(public, clientPublic, (int)length) == (int)length &&
              BN_bn2binpad(shared, secret, (int)length) == (int)length;
    BN_clear_free(private);
    BN_clear_free(shared);
    BN_free(public);
    BN_free(server);
    BN_free(p);
    BN_free(g);
    BN_CTX_free(context);
    return ok;
}

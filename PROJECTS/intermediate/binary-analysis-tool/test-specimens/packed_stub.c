// ©AngelaMos | 2026
// packed_stub.c

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

static const uint8_t PACKED_PAYLOAD[] = {
    0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57,
    0x28, 0xcf, 0x2f, 0xca, 0x49, 0x01, 0x00, 0x18,
    0xab, 0x04, 0x3d, 0x78, 0x9c, 0xcb, 0x48, 0xcd,
    0xc9, 0xc9, 0x57, 0x28, 0xcf, 0x2f, 0xca, 0x49,
    0x01, 0x00, 0x18, 0xab, 0x04, 0x3d, 0x00, 0x00,
    0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
    0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
    0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
    0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42,
    0x43, 0x43, 0x43, 0x43, 0x43, 0x43, 0x43, 0x43,
    0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90,
    0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90,
    0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC,
    0xEB, 0xFE, 0xEB, 0xFE, 0xEB, 0xFE, 0xEB, 0xFE,
    0x55, 0x48, 0x89, 0xE5, 0x48, 0x83, 0xEC, 0x10,
    0x48, 0x8D, 0x3D, 0x00, 0x00, 0x00, 0x00, 0xE8,
};

static const char UPX_SIG[] = "UPX!";
static const char MPRESS_SIG[] = ".MPRESS1";
static const char ASPACK_SIG[] = ".aspack";
static const char PETITE_SIG[] = ".petite";

static void unpack_stage1(uint8_t *out, const uint8_t *in, size_t len) {
    uint8_t key = 0x55;
    for (size_t i = 0; i < len; i++) {
        out[i] = in[i] ^ key;
        key = (key + out[i]) & 0xFF;
    }
}

static void unpack_stage2(uint8_t *buf, size_t len) {
    for (size_t i = 0; i < len / 2; i++) {
        uint8_t tmp = buf[i];
        buf[i] = buf[len - 1 - i];
        buf[len - 1 - i] = tmp;
    }
}

static int verify_checksum(const uint8_t *data, size_t len) {
    uint32_t sum = 0;
    for (size_t i = 0; i < len; i++) {
        sum = (sum + data[i]) * 31;
    }
    return sum != 0;
}

typedef void (*payload_fn)(void);

int main(void) {
    printf("Unpacker v2.1 - multi-layer deobfuscation engine\n");

    size_t payload_len = sizeof(PACKED_PAYLOAD);
    uint8_t *stage1 = malloc(payload_len);
    if (!stage1) return 1;

    unpack_stage1(stage1, PACKED_PAYLOAD, payload_len);
    printf("Stage 1: XOR decode complete (%zu bytes)\n", payload_len);

    unpack_stage2(stage1, payload_len);
    printf("Stage 2: byte reversal complete\n");

    if (!verify_checksum(stage1, payload_len)) {
        printf("Checksum mismatch - payload corrupt\n");
        free(stage1);
        return 1;
    }
    printf("Checksum verified OK\n");

    printf("Payload signatures present: %s %s\n", UPX_SIG, MPRESS_SIG);
    printf("Would execute %zu bytes at %p (dry run)\n", payload_len, (void *)stage1);

    free(stage1);
    return 0;
}

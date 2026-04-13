#include <stdio.h>
#include <string.h>
#include "Daemon/Hardware/ThirdParty/smc.h"
#include "Daemon/Hardware/ThirdParty/smc.c"

static void probe_key(io_connect_t conn, const char* key) {
    UInt32Char_t k;
    strncpy(k, key, 4);
    k[4] = '\0';

    SMCVal_t val;
    memset(&val, 0, sizeof(val));

    kern_return_t kr = SMCReadKey2(k, &val, conn);
    if (kr != KERN_SUCCESS) {
        printf("  %-6s  READ FAILED  (kr=0x%x)\n", key, kr);
        return;
    }

    printf("  %-6s  dataSize=%-2u  type=%.4s  bytes=[ ", key, val.dataSize, val.dataType);
    for (unsigned i = 0; i < val.dataSize && i < 8; i++) {
        printf("0x%02x ", (unsigned char)val.bytes[i]);
    }
    if (val.dataSize == 0) printf("(empty)");
    printf("]\n");
}

static void write_key_test(io_connect_t conn, const char* key, unsigned char byte) {
    unsigned char b = byte;
    kern_return_t kr = SMCWriteSimple((char*)key, &b, 1, conn);
    printf("  write %s = 0x%02x  ->  kr=0x%x (%s)\n",
           key, byte, kr, (kr == KERN_SUCCESS) ? "OK" : "FAILED");
}

int main(void) {
    io_connect_t conn = 0;
    kern_return_t kr = SMCOpen(&conn);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "SMCOpen failed: 0x%x (try: sudo ./probe_smc)\n", kr);
        return 1;
    }

    printf("\n=== SMC Key Probe (M4 Tahoe) ===\n\n");
    printf("-- Tahoe keys --\n");
    probe_key(conn, "CHIE");
    probe_key(conn, "CH0J");

    printf("\n-- Legacy keys (expect dataSize=0 on M4) --\n");
    probe_key(conn, "CH0B");
    probe_key(conn, "CH0C");
    probe_key(conn, "BCLM");
    probe_key(conn, "CH0I");

    printf("\n-- LED + battery --\n");
    probe_key(conn, "ACLC");
    probe_key(conn, "BUIC");

    SMCClose(conn);
    printf("\nDone.\n");
    return 0;
}

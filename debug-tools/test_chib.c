#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "../BatteryCare/battery-care-daemon/Hardware/ThirdParty/smc.h"
#include "../BatteryCare/battery-care-daemon/Hardware/ThirdParty/smc.c"

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
    printf("  %-6s  dataSize=%-2u  bytes=[ ", key, val.dataSize);
    for (unsigned i = 0; i < val.dataSize && i < 8; i++)
        printf("0x%02x ", (unsigned char)val.bytes[i]);
    if (val.dataSize == 0) printf("(empty)");
    printf("]\n");
}

static kern_return_t write1(io_connect_t conn, const char* key, unsigned char val) {
    unsigned char b = val;
    kern_return_t kr = SMCWriteSimple((char*)key, &b, 1, conn);
    if (kr != KERN_SUCCESS)
        kr = SMCWriteForced(key, val, conn);
    return kr;
}

int main(void) {
    io_connect_t conn = 0;
    if (SMCOpen(&conn) != KERN_SUCCESS) {
        fprintf(stderr, "SMCOpen failed (run as root)\n");
        return 1;
    }

    printf("\n=== CHIB / CHIC Write Test ===\n");
    printf("Goal: find which key flips ExternalChargeCapable to No\n");
    printf("Assumption: CHTE=0x01 (charging already disabled by daemon)\n\n");

    printf("-- Before writes --\n");
    probe_key(conn, "CHTE");
    probe_key(conn, "CHIB");
    probe_key(conn, "CHIC");
    probe_key(conn, "CHTM");

    printf("\n-- Writing CHIB=0x02, CHIC=0x02 (inhibit pattern, same as CH0B/CH0C on M1/M2) --\n");
    kern_return_t kr;

    kr = write1(conn, "CHIB", 0x02);
    printf("  CHIB=0x02: kr=0x%x (%s)\n", kr, kr == KERN_SUCCESS ? "OK" : "FAILED");

    kr = write1(conn, "CHIC", 0x02);
    printf("  CHIC=0x02: kr=0x%x (%s)\n", kr, kr == KERN_SUCCESS ? "OK" : "FAILED");

    printf("\n-- After writes --\n");
    probe_key(conn, "CHIB");
    probe_key(conn, "CHIC");

    printf("\nNow check IORegistry in another terminal:\n");
    printf("  ioreg -r -c AppleSmartBattery | grep ExternalChargeCapable\n");
    printf("\nWaiting 5 seconds, then checking if icon changed...\n");
    sleep(5);

    // Re-read
    printf("\n-- After 5s --\n");
    probe_key(conn, "CHIB");
    probe_key(conn, "CHIC");

    printf("\n-- Cleanup: writing CHIB=0x00, CHIC=0x00 --\n");
    write1(conn, "CHIB", 0x00);
    write1(conn, "CHIC", 0x00);
    probe_key(conn, "CHIB");
    probe_key(conn, "CHIC");

    printf("\nDone. Check ExternalChargeCapable again after cleanup:\n");
    printf("  ioreg -r -c AppleSmartBattery | grep ExternalChargeCapable\n");

    SMCClose(conn);
    return 0;
}

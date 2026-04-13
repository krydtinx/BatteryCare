#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "../BatteryCare/battery-care-daemon/Hardware/ThirdParty/smc.h"
#include "../BatteryCare/battery-care-daemon/Hardware/ThirdParty/smc.c"

static void read_chte(io_connect_t conn) {
    UInt32Char_t k = "CHTE";
    SMCVal_t val;
    memset(&val, 0, sizeof(val));
    kern_return_t kr = SMCReadKey2(k, &val, conn);
    printf("  CHTE: kr=0x%x  dataSize=%u  bytes=[ ", kr, val.dataSize);
    for (unsigned i = 0; i < val.dataSize && i < 8; i++)
        printf("0x%02x ", (unsigned char)val.bytes[i]);
    if (val.dataSize == 0) printf("(empty)");
    printf("]\n");
}

int main(void) {
    io_connect_t conn = 0;
    if (SMCOpen(&conn) != KERN_SUCCESS) {
        fprintf(stderr, "SMCOpen failed — try: sudo ./test_chte\n");
        return 1;
    }

    printf("\n=== CHTE pass-through test ===\n\n");

    printf("1. Current state:\n");
    read_chte(conn);

    printf("\n2. Writing CHTE = [0x01 0x00 0x00 0x00]  (disable charging, keep adapter)...\n");
    unsigned char off[4] = {0x01, 0x00, 0x00, 0x00};
    kern_return_t kr = SMCWriteSimple("CHTE", off, 4, conn);
    printf("   write kr=0x%x (%s)\n", kr, kr == KERN_SUCCESS ? "OK" : "FAILED");
    read_chte(conn);

    printf("\n3. Check: run 'pmset -g batt' now — should show 'AC Power' + 'Not Charging'\n");
    printf("   Waiting 5s...\n");
    sleep(5);
    read_chte(conn);

    printf("\n4. Re-enabling charging: CHTE = [0x00 0x00 0x00 0x00]...\n");
    unsigned char on[4] = {0x00, 0x00, 0x00, 0x00};
    kr = SMCWriteSimple("CHTE", on, 4, conn);
    printf("   write kr=0x%x (%s)\n", kr, kr == KERN_SUCCESS ? "OK" : "FAILED");
    read_chte(conn);

    SMCClose(conn);
    printf("\nDone. Check 'pmset -g batt' to confirm charging resumed.\n");
    return 0;
}

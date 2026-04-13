#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "../BatteryCare/battery-care-daemon/Hardware/ThirdParty/smc.h"
#include "../BatteryCare/battery-care-daemon/Hardware/ThirdParty/smc.c"

static unsigned char read_chie(io_connect_t conn) {
    UInt32Char_t k = "CHIE";
    SMCVal_t val;
    memset(&val, 0, sizeof(val));
    SMCReadKey2(k, &val, conn);
    return val.dataSize > 0 ? (unsigned char)val.bytes[0] : 0xFF;
}

int main(void) {
    io_connect_t conn = 0;
    if (SMCOpen(&conn) != KERN_SUCCESS) {
        fprintf(stderr, "SMCOpen failed — run with sudo\n");
        return 1;
    }

    printf("Writing CHIE=0x00 (disable charging)...\n");
    unsigned char b = 0x00;
    SMCWriteSimple("CHIE", &b, 1, conn);

    printf("Monitoring CHIE every 1s for 30s (watching for powerd override):\n\n");
    for (int i = 0; i < 30; i++) {
        unsigned char v = read_chie(conn);
        printf("  t+%2ds  CHIE=0x%02x  %s\n", i, v,
               v == 0x00 ? "holding" : "*** OVERRIDDEN ***");
        fflush(stdout);
        sleep(1);
    }

    printf("\nRe-enabling charging...\n");
    b = 0x01;
    SMCWriteSimple("CHIE", &b, 1, conn);
    printf("  CHIE=0x%02x\n", read_chie(conn));

    SMCClose(conn);
    return 0;
}

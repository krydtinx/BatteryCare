#include <stdio.h>
#include <string.h>
#include "Daemon/Hardware/ThirdParty/smc.h"
#include "Daemon/Hardware/ThirdParty/smc.c"

int main(void) {
    io_connect_t conn = 0;
    if (SMCOpen(&conn) != KERN_SUCCESS) {
        fprintf(stderr, "SMCOpen failed — try: sudo ./reenable_charging\n");
        return 1;
    }
    unsigned char b = 0x00;  // 0x00 = disable inhibit = allow charging + adapter
    kern_return_t kr = SMCWriteSimple("CHIE", &b, 1, conn);
    printf("CHIE write 0x00 (re-enable): %s (kr=0x%x)\n", kr == KERN_SUCCESS ? "OK" : "FAILED", kr);
    SMCClose(conn);
    return kr == KERN_SUCCESS ? 0 : 1;
}

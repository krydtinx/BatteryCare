#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <ctype.h>
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

    printf("  %-6s  dataSize=%-2u  type=%.4s  bytes=[ ", key, val.dataSize, val.dataType);
    for (unsigned i = 0; i < val.dataSize && i < 8; i++) {
        printf("0x%02x ", (unsigned char)val.bytes[i]);
    }
    if (val.dataSize == 0) printf("(empty)");
    printf("]\n");
}

// Enumerate ALL SMC keys via READ_INDEX and filter for charging/battery related
static void enumerate_charging_keys(io_connect_t conn) {
    // First, get key count: read key "#KEY"
    UInt32Char_t countKey = "#KEY";
    SMCVal_t countVal;
    memset(&countVal, 0, sizeof(countVal));
    kern_return_t kr = SMCReadKey2(countKey, &countVal, conn);
    if (kr != KERN_SUCCESS) {
        printf("  Cannot read #KEY (kr=0x%x)\n", kr);
        return;
    }

    UInt32 totalKeys = 0;
    if (countVal.dataSize >= 4) {
        totalKeys = ((UInt32)countVal.bytes[0] << 24) |
                    ((UInt32)countVal.bytes[1] << 16) |
                    ((UInt32)countVal.bytes[2] << 8) |
                    (UInt32)countVal.bytes[3];
    } else if (countVal.dataSize >= 2) {
        totalKeys = ((UInt32)countVal.bytes[0] << 8) | (UInt32)countVal.bytes[1];
    }
    printf("  Total SMC keys: %u\n\n", totalKeys);

    // Iterate all keys via SMC_CMD_READ_INDEX
    printf("  Charging/battery related keys (CH*, BC*, AC*, BU*, B0*):\n\n");

    SMCKeyData_t inputStructure, outputStructure;
    for (UInt32 i = 0; i < totalKeys; i++) {
        memset(&inputStructure, 0, sizeof(inputStructure));
        memset(&outputStructure, 0, sizeof(outputStructure));

        inputStructure.data8 = SMC_CMD_READ_INDEX;
        inputStructure.data32 = i;

        size_t structureOutputSize = sizeof(outputStructure);
        kr = IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC,
                                       &inputStructure, sizeof(inputStructure),
                                       &outputStructure, &structureOutputSize);
        if (kr != KERN_SUCCESS) continue;

        UInt32 keyInt = outputStructure.key;
        char keyStr[5];
        keyStr[0] = (keyInt >> 24) & 0xFF;
        keyStr[1] = (keyInt >> 16) & 0xFF;
        keyStr[2] = (keyInt >> 8) & 0xFF;
        keyStr[3] = keyInt & 0xFF;
        keyStr[4] = '\0';

        // Filter: keys starting with CH, BC, AC, BU, B0, EC
        if ((keyStr[0] == 'C' && keyStr[1] == 'H') ||
            (keyStr[0] == 'B' && keyStr[1] == 'C') ||
            (keyStr[0] == 'A' && keyStr[1] == 'C') ||
            (keyStr[0] == 'B' && keyStr[1] == 'U') ||
            (keyStr[0] == 'B' && keyStr[1] == '0') ||
            (keyStr[0] == 'E' && keyStr[1] == 'C') ||
            (keyStr[0] == 'C' && keyStr[1] == 'H') ||
            (keyStr[0] == 'D' && keyStr[1] == '0')) {
            probe_key(conn, keyStr);
        }
    }
}

int main(int argc, char* argv[]) {
    io_connect_t conn = 0;
    kern_return_t kr = SMCOpen(&conn);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "SMCOpen failed: 0x%x (try: sudo)\n", kr);
        return 1;
    }

    printf("\n=== Icon Investigation: Find ExternalChargeCapable Key ===\n\n");

    // Step 1: Enumerate all charging-related keys
    printf("== Step 1: Enumerate all charging/battery SMC keys ==\n\n");
    enumerate_charging_keys(conn);

    // Step 2: Probe CHTE current state
    printf("\n== Step 2: Current CHTE state ==\n");
    probe_key(conn, "CHTE");

    // Step 3: Try force-write CH0B = 0x02 (even though dataSize=0)
    if (argc > 1 && strcmp(argv[1], "--write") == 0) {
        printf("\n== Step 3: Force-write tests ==\n");
        printf("  Trying SMCWriteForced to CH0B = 0x02...\n");
        kr = SMCWriteForced("CH0B", 0x02, conn);
        printf("  CH0B forced write: kr=0x%x (%s)\n", kr,
               kr == KERN_SUCCESS ? "OK" : "FAILED");

        printf("  Trying SMCWriteForced to CH0C = 0x02...\n");
        kr = SMCWriteForced("CH0C", 0x02, conn);
        printf("  CH0C forced write: kr=0x%x (%s)\n", kr,
               kr == KERN_SUCCESS ? "OK" : "FAILED");

        printf("\n  Now check: ioreg -r -c AppleSmartBattery | grep ExternalChargeCapable\n");
        printf("  If still Yes, run: sudo ./icon_investigation --cleanup\n");
    } else if (argc > 1 && strcmp(argv[1], "--cleanup") == 0) {
        printf("\n== Cleanup: Force-write CH0B=0x00, CH0C=0x00 ==\n");
        SMCWriteForced("CH0B", 0x00, conn);
        SMCWriteForced("CH0C", 0x00, conn);
        printf("  Done.\n");
    } else {
        printf("\n== Step 3: To try force-writes, re-run with --write ==\n");
        printf("  sudo ./icon_investigation --write\n");
    }

    SMCClose(conn);
    printf("\nDone.\n");
    return 0;
}

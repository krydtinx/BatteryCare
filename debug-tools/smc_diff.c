#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "../BatteryCare/battery-care-daemon/Hardware/ThirdParty/smc.h"
#include "../BatteryCare/battery-care-daemon/Hardware/ThirdParty/smc.c"

// Keys to snapshot: all CH* keys that have dataSize > 0 on M4, plus AC status keys
static const char* WATCH_KEYS[] = {
    "CHTE", "CHTM", "CHCC", "CHCE", "CHCR", "CHCF",
    "CHIB", "CHIC", "CHSC", "CHSE", "CHST", "CHRT",
    "CHFS", "CHIF", "CHIS", "CHPS",
    "CH0D", "CH0R", "CH0V",
    "CHOC", "CHLT", "CHTL", "CHTU",
    "CHDB",
    "AC-C", "AC-S", "AC-B", "AC-F", "AC-U",
    "ACLC", "BUIC",
    "B0CM",  // battery charge max %
    NULL
};

typedef struct {
    unsigned char bytes[32];
    unsigned int  size;
    int           valid;
} Snapshot;

static Snapshot snapshots_before[64];
static Snapshot snapshots_after[64];

static void take_snapshot(io_connect_t conn, Snapshot* snaps) {
    for (int i = 0; WATCH_KEYS[i] != NULL; i++) {
        UInt32Char_t k;
        strncpy(k, WATCH_KEYS[i], 4);
        k[4] = '\0';
        SMCVal_t val;
        memset(&val, 0, sizeof(val));
        kern_return_t kr = SMCReadKey2(k, &val, conn);
        if (kr == KERN_SUCCESS) {
            snaps[i].size = val.dataSize < 32 ? val.dataSize : 32;
            memcpy(snaps[i].bytes, val.bytes, snaps[i].size);
            snaps[i].valid = 1;
        } else {
            snaps[i].valid = 0;
        }
    }
}

static void print_bytes(const unsigned char* b, unsigned size) {
    for (unsigned i = 0; i < size && i < 8; i++)
        printf("0x%02x ", b[i]);
    if (size == 0) printf("(empty)");
}

int main(void) {
    io_connect_t conn = 0;
    if (SMCOpen(&conn) != KERN_SUCCESS) {
        fprintf(stderr, "SMCOpen failed (run as root)\n");
        return 1;
    }

    printf("\n=== SMC Diff: Enable vs Disable Charging ===\n");
    printf("This tool snapshots key values before/after toggling CHTE.\n\n");

    // Step 1: snapshot with CHTE=0x01 (disabled, current state)
    printf("Step 1: Snapshot with CHTE=0x01 (charging DISABLED)...\n");
    take_snapshot(conn, snapshots_before);

    // Step 2: enable charging (write CHTE=0x00)
    unsigned char enable[4] = {0x00, 0x00, 0x00, 0x00};
    kern_return_t kr = SMCWriteSimple("CHTE", enable, 4, conn);
    printf("Step 2: Write CHTE=0x00 (enable charging): kr=0x%x (%s)\n",
           kr, kr == KERN_SUCCESS ? "OK" : "FAILED");

    sleep(2); // let firmware settle

    // Step 3: snapshot with CHTE=0x00 (enabled)
    printf("Step 3: Snapshot with CHTE=0x00 (charging ENABLED, after 2s)...\n");
    take_snapshot(conn, snapshots_after);

    // Step 4: restore CHTE=0x01 (disable charging again)
    unsigned char disable[4] = {0x01, 0x00, 0x00, 0x00};
    kr = SMCWriteSimple("CHTE", disable, 4, conn);
    printf("Step 4: Restore CHTE=0x01 (disable charging): kr=0x%x (%s)\n\n",
           kr, kr == KERN_SUCCESS ? "OK" : "FAILED");

    // Step 5: diff
    printf("=== DIFF (keys that changed between disabled -> enabled) ===\n\n");
    int found_diff = 0;
    for (int i = 0; WATCH_KEYS[i] != NULL; i++) {
        Snapshot* b = &snapshots_before[i];
        Snapshot* a = &snapshots_after[i];
        if (!b->valid || !a->valid) continue;
        if (b->size != a->size || memcmp(b->bytes, a->bytes, b->size) != 0) {
            found_diff = 1;
            printf("  %-6s  DISABLED=[ ", WATCH_KEYS[i]);
            print_bytes(b->bytes, b->size);
            printf("]  ENABLED=[ ");
            print_bytes(a->bytes, a->size);
            printf("]\n");
        }
    }
    if (!found_diff)
        printf("  No differences found among watched keys.\n");

    printf("\n=== All watched key values (for reference) ===\n\n");
    for (int i = 0; WATCH_KEYS[i] != NULL; i++) {
        Snapshot* b = &snapshots_before[i];
        if (!b->valid) continue;
        printf("  %-6s  [ ", WATCH_KEYS[i]);
        print_bytes(b->bytes, b->size);
        printf("]\n");
    }

    SMCClose(conn);
    printf("\nDone.\n");
    return 0;
}

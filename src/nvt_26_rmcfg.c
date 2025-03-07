#include <unistd.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <signal.h>

// nvos.h
typedef struct {
    uint32_t hRoot;
    uint32_t hObjectParent;
    uint32_t hObjectNew;
    uint32_t hClass;
    uint64_t pAllocParms __attribute__ ((aligned (8)));
    uint32_t paramsSize;
    uint32_t status;
} NVOS21_PARAMETERS;

typedef struct {
    uint32_t hClient;
    uint32_t hObject;
    uint32_t cmd;
    uint32_t flags;
    uint64_t params __attribute__ ((aligned (8)));
    uint32_t paramsSize;
    uint32_t status;
} NVOS54_PARAMETERS;

typedef struct NV0080_ALLOC_PARAMETERS {
    uint32_t deviceId;
    uint32_t hClientShare;
    uint32_t hTargetClient;
    uint32_t hTargetDevice;
    uint32_t flags;
    uint64_t vaSpaceSize __attribute__ ((aligned (8)));
    uint64_t vaStartInternal __attribute__ ((aligned (8)));
    uint64_t vaLimitInternal __attribute__ ((aligned (8)));
    uint32_t vaMode;
} NV0080_ALLOC_PARAMETERS;

typedef struct NV2080_ALLOC_PARAMETERS {
    uint32_t subDeviceId;
} NV2080_ALLOC_PARAMETERS;

#define NV0000_CTRL_CMD_SYSTEM_DEBUG_RMMSG_CTRL     (0x121U)
#define NV0000_CTRL_SYSTEM_DEBUG_RMMSG_SIZE         512U
#define NV0000_CTRL_SYSTEM_DEBUG_RMMSG_CTRL_CMD_GET (0x00000000U)
#define NV0000_CTRL_SYSTEM_DEBUG_RMMSG_CTRL_CMD_SET (0x00000001U)
#define NV0000_CTRL_SYSTEM_DEBUG_RMMSG_CTRL_PARAMS_MESSAGE_ID (0x21U)
typedef struct NV0000_CTRL_SYSTEM_DEBUG_RMMSG_CTRL_PARAMS {
    uint32_t cmd;
    uint32_t count;
    uint8_t  data[NV0000_CTRL_SYSTEM_DEBUG_RMMSG_SIZE];
} NV0000_CTRL_SYSTEM_DEBUG_RMMSG_CTRL_PARAMS;

#define NV00DE_RUSD_POLL_CLOCK     0x1
#define NV00DE_RUSD_POLL_PERF      0x2
#define NV00DE_RUSD_POLL_MEMORY    0x4
#define NV00DE_RUSD_POLL_POWER     0x8
#define NV00DE_RUSD_POLL_THERMAL   0x10
#define NV00DE_RUSD_POLL_PCI       0x20

typedef struct NV00DE_ALLOC_PARAMETERS {
    uint64_t polledDataMask;
} NV00DE_ALLOC_PARAMETERS;

static int nvctl;
static int nvdev;
static uint32_t hClient;
static uint32_t hDevice = 0xabcd0080;
static uint32_t hSubdevice = 0xabcd2080;

static inline void NvRmAlloc(NVOS21_PARAMETERS *params) {
    int status = ioctl(nvctl, _IOWR('F', 0x2B, NVOS21_PARAMETERS), params);
    if (status < 0) {
        perror("NvRmAlloc failed in OS");
        exit(-1);
    }
    if (params->status != 0) {
        fprintf(stderr, "NvRmAlloc (hClass=0x%04x) failed in RM: 0x%08x\n", params->hClass, params->status);
        exit(-1);
    }
}

static inline void NvRmControl(NVOS54_PARAMETERS *params) {
    int status = ioctl(nvctl, _IOWR('F', 0x2A, NVOS54_PARAMETERS), params);
    if (status < 0) {
        perror("NvRmControl failed in OS");
        exit(-1);
    }
    if (params->status != 0) {
        fprintf(stderr, "NvRmControl 0x%08x failed in RM: 0x%08x\n", params->cmd, params->status);
        exit(-1);
    }
}

static inline void init() {
    nvctl = open("/dev/nvidiactl", O_RDWR);
    if (nvctl < 0) {
        perror("Unable to open /dev/nvidiactl");
        exit(-1);
    }
    nvdev = open("/dev/nvidia0", O_RDWR);
    if (nvdev < 0) {
        perror("Unable to open /dev/nvidia0");
        exit(-1);
    }

    NVOS21_PARAMETERS alloc = {0};
    NvRmAlloc(&alloc);
    hClient = alloc.hObjectNew;

    memset(&alloc, 0, sizeof(alloc));
    NV0080_ALLOC_PARAMETERS alloc0080 = {0};
    alloc.hRoot = hClient;
    alloc.hObjectParent = hClient;
    alloc.hObjectNew = hDevice;
    alloc.hClass = 0x0080;
    alloc.pAllocParms = (uintptr_t)&alloc0080;
    alloc.paramsSize = sizeof(alloc0080);
    NvRmAlloc(&alloc);

    uint32_t hSubdevice = 0xabcd2080;
    memset(&alloc, 0, sizeof(alloc));
    NV2080_ALLOC_PARAMETERS alloc2080 = {0};
    alloc.hRoot = hClient;
    alloc.hObjectParent = hDevice;
    alloc.hObjectNew = hSubdevice;
    alloc.hClass = 0x2080;
    alloc.pAllocParms = (uintptr_t)&alloc2080;
    alloc.paramsSize = sizeof(alloc2080);
    NvRmAlloc(&alloc);
}
struct {
    struct {
        bool present;
        char value[NV0000_CTRL_SYSTEM_DEBUG_RMMSG_SIZE];
    } rmmsg;
    struct {
        bool present;
        uint32_t value;
    } rusd;
} args;
void parse_args(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <options>\n", argv[0]);
        fprintf(stderr, "Options:\n");
        fprintf(stderr, "  --rmmsg <message>\n");
        fprintf(stderr, "  --rusd <polling_mask>\n");
        exit(-1);
    }

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--rmmsg") == 0) {
            if (i + 1 < argc) {
                args.rmmsg.present = true;
                strncpy(args.rmmsg.value, argv[i + 1], sizeof(args.rmmsg.value));
            } else {
                fprintf(stderr, "Missing argument for --rmmsg\n");
                exit(-1);
            }
        } else if (strcmp(argv[i], "--rusd") == 0) {
            if (i + 1 < argc) {
                args.rusd.present = true;
                args.rusd.value = strtoul(argv[i + 1], NULL, 0);
            } else {
                fprintf(stderr, "Missing argument for --rusd\n");
                exit(-1);
            }
        }
    }
}

volatile int exit_requested = 0;
void sigint_handler(int signum) {
    exit_requested = 1;
}

int main(int argc, char *argv[]) {
    init();
    parse_args(argc, argv);

    NVOS54_PARAMETERS ctrl = {0};
    ctrl.hClient = hClient;
    
    char old_rmmsg[NV0000_CTRL_SYSTEM_DEBUG_RMMSG_SIZE] = {0};
    NV0000_CTRL_SYSTEM_DEBUG_RMMSG_CTRL_PARAMS rmmsg = {0};
    
    if (args.rmmsg.present) {
        ctrl.hObject = hClient;
        ctrl.cmd = NV0000_CTRL_CMD_SYSTEM_DEBUG_RMMSG_CTRL;
        ctrl.params = (uintptr_t)&rmmsg;
        ctrl.paramsSize = sizeof(rmmsg);
        rmmsg.cmd = NV0000_CTRL_SYSTEM_DEBUG_RMMSG_CTRL_CMD_GET;
        NvRmControl(&ctrl);
        memcpy(old_rmmsg, rmmsg.data, sizeof(old_rmmsg));

        rmmsg.cmd = NV0000_CTRL_SYSTEM_DEBUG_RMMSG_CTRL_CMD_SET;
        memcpy(rmmsg.data, args.rmmsg.value, sizeof(rmmsg.data));
        NvRmControl(&ctrl);

        printf("rmcfg: Changed RmMsg '%s' -> '%s'\n", old_rmmsg, args.rmmsg.value);
    }

    if (args.rusd.present) {
        NV00DE_ALLOC_PARAMETERS alloc00de = {0};
        alloc00de.polledDataMask = args.rusd.value;
        NVOS21_PARAMETERS alloc = {0};
        alloc.hClass = 0x00DE;
        alloc.hRoot = hClient;
        alloc.hObjectParent = hSubdevice;
        alloc.hObjectNew = 0xabcd00de;
        alloc.pAllocParms = (uintptr_t)&alloc00de;
        alloc.paramsSize = sizeof(alloc00de);
        NvRmAlloc(&alloc);
        printf("rmcfg: Changed RUSD polling mask to 0x%08x\n", args.rusd.value);
    }

    signal(SIGINT, sigint_handler);
    signal(SIGTERM, sigint_handler);
    while (!exit_requested) {
        sleep(1);
    }
    
    if (args.rmmsg.present) {
        rmmsg.cmd = NV0000_CTRL_SYSTEM_DEBUG_RMMSG_CTRL_CMD_SET;
        memcpy(rmmsg.data, old_rmmsg, sizeof(rmmsg.data));
        NvRmControl(&ctrl);
        printf("rmcfg: Restored RmMsg '%s'\n", old_rmmsg);
    }
}


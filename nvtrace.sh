#!/bin/sh

echo "nvtrace performance and stutter diagnostics tool, version 0.2"
echo ""
echo "Leave the tool running in the background to collect traces"
echo "If you notice stutter or performance issues, double-tap the ALT key."
echo ""
echo "When you are done, press CTRL+C to stop the trace and generate a report."
echo ""

if [ "$(id -u)" -ne 0 ]; then
    echo "Not running as root, individual commands may ask for sudo password."
    is_root=0
else
    is_root=1
fi

outdir=$(mktemp -d)
echo "Our temporary directory is $outdir"

nvidia_version=$(cat /sys/module/nvidia/version)
if [ -z "$nvidia_version" ]; then
    echo "ERROR: NVIDIA driver not found"
    exit 1
fi

ver_major=$(echo $nvidia_version | cut -d. -f1)
ver_minor=$(echo $nvidia_version | cut -d. -f2)
ver_patch=$(echo $nvidia_version | cut -d. -f3)

# TODO: Only supported on OpenRM for now. Need to divine the offsets for the proprietary driver.
nvidia_license=$(modinfo nvidia | grep license | awk '{$1=""; print}')
if [ "$nvidia_license" != " Dual MIT/GPL" ]; then
    echo "ERROR: nvtrace only works with the Open Source NVIDIA GPU kernel modules"
    exit 1
fi

trace_only=
for arg in "$@"; do
    if [ "$arg" = "--trace-only" ]; then
        trace_only=1
        echo "Running in trace-only mode"
        shift
        break
    fi
done
if [ -z "$trace_only" ]; then
    echo "Running nvidia-bug-report.sh, this may take a minute..."
    sudo nvidia-bug-report.sh --output-file $outdir/nvidia-bug-report-start.log > /dev/null
fi

# Fetch a recent bpftrace binary since most distros ship very old versions.
# TODO: Check installed version if any and skip this step...
if [ ! -f nvt-bpftrace ]; then
    bpftrace_link="https://github.com/bpftrace/bpftrace/releases/download/v0.21.2/bpftrace"
    echo ""
    echo "nvtrace requires a recent bpftrace binary to run."
    echo "It will now download the binary from: "
    echo "    $bpftrace_link"
    echo ""
    wget $bpftrace_link
    mv bpftrace nvt-bpftrace
    chmod +x nvt-bpftrace
    echo "bpftrace binary saved as $(pwd)/nvt-bpftrace"
    echo ""
fi

# Get the address of global variables
gpsys=$(sudo grep g_pSys /proc/kallsyms | awk '{print $1}' | xargs printf "0x%s")
cat << EOF > $outdir/rmcfg.c
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

EOF
# ^ end the cat started in rmcfg_pre.sh

gcc -o $outdir/nvt-rmcfg \
    -DVER_MAJOR=$ver_major -DVER_MINOR=$ver_minor -DVER_PATCH=$ver_patch \
    $outdir/rmcfg.c
ctrl_c() {
    echo ""
    echo "CTRL+C received, stopping trace.."
    echo ""
    sudo killall -s INT nvt-bpftrace
    sudo killall -s INT nvt-rmcfg
}

trap ctrl_c INT

# Log: >= Notice; anything GSP related
# RUSD: PERF (pstate)
sudo $outdir/nvt-rmcfg --rmmsg "@2,gsp" --rusd 0x0002 &
# Preprocess and then run the bpftrace script..

CPPFLAGS="$offsets -DADDR_PSYS=$gpsys \
-DVER_MAJOR=$ver_major -DVER_MINOR=$ver_minor -DVER_PATCH=$ver_patch"

echo "Starting bpftrace.."

# bpftrace will be stopped by ctrl_c() trap handler
grep --after-context=9999999 'BEGIN[_]BPFTRACE[_]SCRIPT' $0 | cpp -P $CPPFLAGS $* - | xargs -0 sudo ./nvt-bpftrace -e  > $outdir/bpftrace.log &

# Display output to user too
tail -f $outdir/bpftrace.log
sleep 2
if [ -z "$trace_only" ]; then
    echo ""
    echo "Will collect trace end system state"
    echo "Running nvidia-bug-report.sh, this may take a minute..."
    echo ""
    sudo nvidia-bug-report.sh --output-file $outdir/nvidia-bug-report-end.log > /dev/null
fi
# Tar up everything in outdir and copy to pwd

if [ -z "$trace_only" ]; then
    tarname=nvtrace-$(date +%Y%m%d%H%M%S).tar.gz

    #tar -czf $tarname $outdir/*
    oldpwd=$(pwd)
    cd $outdir
    tar -czf $oldpwd/$tarname *
    cd $oldpwd


    echo ""
    echo "Saved trace output to $tarname"
    echo "Please send this file to mtijanic@nvidia.com for analysis."
    echo ""
fi

if [ -z "$trace_only" ]; then
    echo ""
    echo "By delivering this file to NVIDIA, you acknowledge"
    echo "and agree that personal information may inadvertently be included in"
    echo "the output.  Notwithstanding the foregoing, NVIDIA will use the"
    echo "output only for the purpose of investigating your reported issue."
    echo ""
fi
if [ ! -z "$outdir" ]; then
    echo "Cleaning up $outdir"
    echo ""
    rm -rf $outdir
fi


exit


#define BEGIN_BPFTRACE_SCRIPT
//
// CONFIG - pass as -DFOO=1 to the script
//

// Minimum duration (in usec) of an ioctl before it can be logged. 0: log all
#ifndef MINTIME
#define MINTIME 0
#endif

// Duration (in usec) above which the print will be highlighted
#ifndef WARNTIME
#define WARNTIME 1000
#endif

// You can optionally pass a FILTER for when to profile, some examples:
//     '-DFILTER=(comm=="nvidia-smi")'
//     '-DFILTER=(comm!="Xorg"&&comm!="xfwm4")'
//     '-DFILTER=($ctl==0x2A)'
#ifndef FILTER
#define FILTER 1
#endif

#define COLOR_DIM "\033[2m"
#define COLOR_BOLD "\033[1;31m"
#define COLOR_RESET "\033[0m"
#define DRIVER_VERSION (VER_MAJOR * 100000 + VER_MINOR * 100 + VER_PATCH)
#define IS_VERSION(x,y,z) (DRIVER_VERSION == (x * 100000 + y * 100 + z))
#define IS_VERSION_OR_ABOVE(x,y,z) (DRIVER_VERSION >= (x * 100000 + y * 100 + z))

#define DEF_FIELD_16(esc, x) unsigned short x;
#define DEF_FIELD_32(esc, x) unsigned int x;
#define DEF_FIELD_64(esc, x) unsigned long x;
#define DEF_FIELD(esc, size, x) DEF_FIELD_ ##size(esc, x)

#define PRINT_FIELD_16(esc, fld) printf("%s=0x%hx, ",    #fld, ((struct PARAMS_##esc *)$ptr)->fld);
#define PRINT_FIELD_32(esc, fld) printf("%s=0x%x, ",    #fld, ((struct PARAMS_##esc *)$ptr)->fld);
#define PRINT_FIELD_64(esc, fld) printf("%s=0x%llx, ", #fld, ((struct PARAMS_##esc *)$ptr)->fld);
#define PRINT_FIELD(esc, size, fld) PRINT_FIELD_##size(esc, fld)

#define EXPAND(...) __VA_ARGS__
#define DISCARD(...)

#define NV_ESC_RM_ALLOC_MEMORY(X_ID, X_FIELD) \
    X_ID(0x27) \
    X_FIELD(NV_ESC_RM_ALLOC_MEMORY, 32, hRoot) \
    X_FIELD(NV_ESC_RM_ALLOC_MEMORY, 32, hObjectParent) \
    X_FIELD(NV_ESC_RM_ALLOC_MEMORY, 32, hObjectNew) \
    X_FIELD(NV_ESC_RM_ALLOC_MEMORY, 32, hClass) \
    X_FIELD(NV_ESC_RM_ALLOC_MEMORY, 32, flags) \
    X_FIELD(NV_ESC_RM_ALLOC_MEMORY, 32, _padding) \
    X_FIELD(NV_ESC_RM_ALLOC_MEMORY, 64, pMemory) \
    X_FIELD(NV_ESC_RM_ALLOC_MEMORY, 64, limit) \
    X_FIELD(NV_ESC_RM_ALLOC_MEMORY, 32, status) \


#define NV_ESC_RM_ALLOC_OBJECT(X_ID, X_FIELD) \
    X_ID(0x28) \
    X_FIELD(NV_ESC_RM_ALLOC_OBJECT, 32, hRoot) \
    X_FIELD(NV_ESC_RM_ALLOC_OBJECT, 32, hObjectParent) \
    X_FIELD(NV_ESC_RM_ALLOC_OBJECT, 32, hObjectNew) \
    X_FIELD(NV_ESC_RM_ALLOC_OBJECT, 32, hClass) \
    X_FIELD(NV_ESC_RM_ALLOC_OBJECT, 32, status) \


#define NV_ESC_RM_FREE(X_ID, X_FIELD) \
    X_ID(0x29) \
    X_FIELD(NV_ESC_RM_FREE, 32, hRoot) \
    X_FIELD(NV_ESC_RM_FREE, 32, hObjectParent) \
    X_FIELD(NV_ESC_RM_FREE, 32, hObjectOld) \
    X_FIELD(NV_ESC_RM_FREE, 32, status) \


#define NV_ESC_RM_CONTROL(X_ID, X_FIELD) \
    X_ID(0x2A) \
    X_FIELD(NV_ESC_RM_CONTROL, 32, hClient) \
    X_FIELD(NV_ESC_RM_CONTROL, 32, hObject) \
    X_FIELD(NV_ESC_RM_CONTROL, 32, cmd) \
    X_FIELD(NV_ESC_RM_CONTROL, 32, flags) \
    X_FIELD(NV_ESC_RM_CONTROL, 64, params) \
    X_FIELD(NV_ESC_RM_CONTROL, 32, paramsSize) \
    X_FIELD(NV_ESC_RM_CONTROL, 32, status) \


#define NV_ESC_RM_ALLOC(X_ID, X_FIELD) \
    X_ID(0x2B) \
    X_FIELD(NV_ESC_RM_ALLOC, 32, hRoot) \
    X_FIELD(NV_ESC_RM_ALLOC, 32, hObjectParent) \
    X_FIELD(NV_ESC_RM_ALLOC, 32, hObjectNew) \
    X_FIELD(NV_ESC_RM_ALLOC, 32, hClass) \
    X_FIELD(NV_ESC_RM_ALLOC, 64, pAllocParms) \
    X_FIELD(NV_ESC_RM_ALLOC, 32, status) \

#define NV_ESC_RM_DUP_OBJECT(X_ID, X_FIELD) \
    X_ID(0x34) \
    X_FIELD(NV_ESC_RM_DUP_OBJECT, 32, hClient) \
    X_FIELD(NV_ESC_RM_DUP_OBJECT, 32, hParent) \
    X_FIELD(NV_ESC_RM_DUP_OBJECT, 32, hObject) \
    X_FIELD(NV_ESC_RM_DUP_OBJECT, 32, hClientSrc) \
    X_FIELD(NV_ESC_RM_DUP_OBJECT, 32, hObjectSrc) \
    X_FIELD(NV_ESC_RM_DUP_OBJECT, 32, flags) \
    X_FIELD(NV_ESC_RM_DUP_OBJECT, 32, status) \


#define NV_ESC_RM_SHARE(X_ID, X_FIELD) \
    X_ID(0x35) \
    X_FIELD(NV_ESC_RM_SHARE, 32, hClient) \
    X_FIELD(NV_ESC_RM_SHARE, 32, hObject) \
    /*RS_SHARE_POLICY    sharePolicy;*/ \
    /*X_FIELD(NV_ESC_RM_SHARE, 32, status) */ \


#define NV_ESC_RM_I2C_ACCESS(X_ID, X_FIELD) \
    X_ID(0x39) \
    X_FIELD(NV_ESC_RM_I2C_ACCESS, 32, hClient) \
    X_FIELD(NV_ESC_RM_I2C_ACCESS, 32, hDevice) \
    X_FIELD(NV_ESC_RM_I2C_ACCESS, 32, paramSize) \
    X_FIELD(NV_ESC_RM_I2C_ACCESS, 32, _padding) \
    X_FIELD(NV_ESC_RM_I2C_ACCESS, 64, paramStructPtr) \
    X_FIELD(NV_ESC_RM_I2C_ACCESS, 32, status) \



#define NV_ESC_RM_IDLE_CHANNELS(X_ID, X_FIELD) \
    X_ID(0x41) \
    X_FIELD(NV_ESC_RM_IDLE_CHANNELS, 32, hClient) \
    X_FIELD(NV_ESC_RM_IDLE_CHANNELS, 32, hDevice) \
    X_FIELD(NV_ESC_RM_IDLE_CHANNELS, 32, hChannel) \
    X_FIELD(NV_ESC_RM_IDLE_CHANNELS, 32, numChannels) \
    X_FIELD(NV_ESC_RM_IDLE_CHANNELS, 64, phClients) \
    X_FIELD(NV_ESC_RM_IDLE_CHANNELS, 64, phDevices) \
    X_FIELD(NV_ESC_RM_IDLE_CHANNELS, 64, phChannels) \
    X_FIELD(NV_ESC_RM_IDLE_CHANNELS, 32, flags) \
    X_FIELD(NV_ESC_RM_IDLE_CHANNELS, 32, timeout) \
    X_FIELD(NV_ESC_RM_IDLE_CHANNELS, 32, status) \


#define NV_ESC_RM_VID_HEAP_CONTROL(X_ID, X_FIELD) \
    X_ID(0x4A) \
    X_FIELD(NV_ESC_RM_VID_HEAP_CONTROL, 32, hRoot) \
    X_FIELD(NV_ESC_RM_VID_HEAP_CONTROL, 32, hObjectParent) \
    X_FIELD(NV_ESC_RM_VID_HEAP_CONTROL, 32, function) \
    X_FIELD(NV_ESC_RM_VID_HEAP_CONTROL, 32, hVASpace) \
    X_FIELD(NV_ESC_RM_VID_HEAP_CONTROL, 16, ivcHeapNumber) \
    X_FIELD(NV_ESC_RM_VID_HEAP_CONTROL, 32, status) \
    X_FIELD(NV_ESC_RM_VID_HEAP_CONTROL, 64, total) \
    X_FIELD(NV_ESC_RM_VID_HEAP_CONTROL, 64, free) \
    X_FIELD(NV_ESC_RM_VID_HEAP_CONTROL, 32, data0) \
    X_FIELD(NV_ESC_RM_VID_HEAP_CONTROL, 32, data1) \
    X_FIELD(NV_ESC_RM_VID_HEAP_CONTROL, 32, data2) \
    X_FIELD(NV_ESC_RM_VID_HEAP_CONTROL, 32, data3) \
    // ..etc...


#define NV_ESC_RM_ACCESS_REGISTRY(X_ID, X_FIELD) \
    X_ID(0x4D) \
    X_FIELD(NV_ESC_RM_ACCESS_REGISTRY, 32, hClient) \
    X_FIELD(NV_ESC_RM_ACCESS_REGISTRY, 32, hObject) \
    X_FIELD(NV_ESC_RM_ACCESS_REGISTRY, 32, AccessType) \
    X_FIELD(NV_ESC_RM_ACCESS_REGISTRY, 32, DevNodeLength) \
    X_FIELD(NV_ESC_RM_ACCESS_REGISTRY, 64, pDevNode) \
    X_FIELD(NV_ESC_RM_ACCESS_REGISTRY, 32, ParmStrLength) \
    X_FIELD(NV_ESC_RM_ACCESS_REGISTRY, 32, _padding0) \
    X_FIELD(NV_ESC_RM_ACCESS_REGISTRY, 64, pParmStr) \
    X_FIELD(NV_ESC_RM_ACCESS_REGISTRY, 32, BinaryDataLength) \
    X_FIELD(NV_ESC_RM_ACCESS_REGISTRY, 32, _padding1) \
    X_FIELD(NV_ESC_RM_ACCESS_REGISTRY, 64, pBinaryData) \
    X_FIELD(NV_ESC_RM_ACCESS_REGISTRY, 32, Data) \
    X_FIELD(NV_ESC_RM_ACCESS_REGISTRY, 32, Entry) \
    X_FIELD(NV_ESC_RM_ACCESS_REGISTRY, 32, status) \


#define NV_ESC_RM_MAP_MEMORY(X_ID, X_FIELD) \
    X_ID(0x4E) \
    X_FIELD(NV_ESC_RM_MAP_MEMORY, 32, hClient) \
    X_FIELD(NV_ESC_RM_MAP_MEMORY, 32, hDevice) \
    X_FIELD(NV_ESC_RM_MAP_MEMORY, 32, hMemory) \
    X_FIELD(NV_ESC_RM_MAP_MEMORY, 32, _padding) \
    X_FIELD(NV_ESC_RM_MAP_MEMORY, 64, offset) \
    X_FIELD(NV_ESC_RM_MAP_MEMORY, 64, length) \
    X_FIELD(NV_ESC_RM_MAP_MEMORY, 64, pLinearAddress) \
    X_FIELD(NV_ESC_RM_MAP_MEMORY, 32, status) \
    X_FIELD(NV_ESC_RM_MAP_MEMORY, 32, flags) \



#define NV_ESC_RM_UNMAP_MEMORY(X_ID, X_FIELD) \
    X_ID(0x4F) \
    X_FIELD(NV_ESC_RM_UNMAP_MEMORY, 32, hClient) \
    X_FIELD(NV_ESC_RM_UNMAP_MEMORY, 32, hDevice) \
    X_FIELD(NV_ESC_RM_UNMAP_MEMORY, 32, hMemory) \
    X_FIELD(NV_ESC_RM_UNMAP_MEMORY, 32, _padding) \
    X_FIELD(NV_ESC_RM_UNMAP_MEMORY, 64, pLinearAddress) \
    X_FIELD(NV_ESC_RM_UNMAP_MEMORY, 32, status) \
    X_FIELD(NV_ESC_RM_UNMAP_MEMORY, 32, flags) \


#define NV_ESC_RM_GET_EVENT_DATA(X_ID, X_FIELD) \
    X_ID(0x52) \
    X_FIELD(NV_ESC_RM_GET_EVENT_DATA, 64, pEvent) \
    X_FIELD(NV_ESC_RM_GET_EVENT_DATA, 32, MoreEvents) \
    X_FIELD(NV_ESC_RM_GET_EVENT_DATA, 32, status) \


#define NV_ESC_RM_ALLOC_CONTEXT_DMA2(X_ID, X_FIELD) \
    X_ID(0x54) \
    X_FIELD(NV_ESC_RM_ALLOC_CONTEXT_DMA2, 32, hObjectParent) \
    X_FIELD(NV_ESC_RM_ALLOC_CONTEXT_DMA2, 32, hSubDevice) \
    X_FIELD(NV_ESC_RM_ALLOC_CONTEXT_DMA2, 32, hObjectNew) \
    X_FIELD(NV_ESC_RM_ALLOC_CONTEXT_DMA2, 32, hClass) \
    X_FIELD(NV_ESC_RM_ALLOC_CONTEXT_DMA2, 32, flags) \
    X_FIELD(NV_ESC_RM_ALLOC_CONTEXT_DMA2, 32, selector) \
    X_FIELD(NV_ESC_RM_ALLOC_CONTEXT_DMA2, 32, hMemory) \
    X_FIELD(NV_ESC_RM_ALLOC_CONTEXT_DMA2, 32, _padding) \
    X_FIELD(NV_ESC_RM_ALLOC_CONTEXT_DMA2, 64, offset) \
    X_FIELD(NV_ESC_RM_ALLOC_CONTEXT_DMA2, 64, limit) \
    X_FIELD(NV_ESC_RM_ALLOC_CONTEXT_DMA2, 32, status) \


#define NV_ESC_RM_MAP_MEMORY_DMA(X_ID, X_FIELD) \
    X_ID(0x57) \
    X_FIELD(NV_ESC_RM_MAP_MEMORY_DMA, 32, hClient) \
    X_FIELD(NV_ESC_RM_MAP_MEMORY_DMA, 32, hDevice) \
    X_FIELD(NV_ESC_RM_MAP_MEMORY_DMA, 32, hDma) \
    X_FIELD(NV_ESC_RM_MAP_MEMORY_DMA, 32, hMemory) \
    X_FIELD(NV_ESC_RM_MAP_MEMORY_DMA, 64, offset) \
    X_FIELD(NV_ESC_RM_MAP_MEMORY_DMA, 64, length) \
    X_FIELD(NV_ESC_RM_MAP_MEMORY_DMA, 32, flags) \
    X_FIELD(NV_ESC_RM_MAP_MEMORY_DMA, 32, _padding) \
    X_FIELD(NV_ESC_RM_MAP_MEMORY_DMA, 64, dmaOffset) \
    X_FIELD(NV_ESC_RM_MAP_MEMORY_DMA, 32, status) \


#define NV_ESC_RM_UNMAP_MEMORY_DMA(X_ID, X_FIELD) \
    X_ID(0x58) \
    X_FIELD(NV_ESC_RM_UNMAP_MEMORY_DMA, 32, hClient) \
    X_FIELD(NV_ESC_RM_UNMAP_MEMORY_DMA, 32, hDevice) \
    X_FIELD(NV_ESC_RM_UNMAP_MEMORY_DMA, 32, hDma) \
    X_FIELD(NV_ESC_RM_UNMAP_MEMORY_DMA, 32, hMemory) \
    X_FIELD(NV_ESC_RM_UNMAP_MEMORY_DMA, 32, flags) \
    X_FIELD(NV_ESC_RM_UNMAP_MEMORY_DMA, 32, _padding) \
    X_FIELD(NV_ESC_RM_UNMAP_MEMORY_DMA, 64, dmaOffset) \
    X_FIELD(NV_ESC_RM_UNMAP_MEMORY_DMA, 32, status) \


#define NV_ESC_RM_BIND_CONTEXT_DMA(X_ID, X_FIELD) \
    X_ID(0x59) \
    X_FIELD(NV_ESC_RM_BIND_CONTEXT_DMA, 32, hClient) \
    X_FIELD(NV_ESC_RM_BIND_CONTEXT_DMA, 32, hChannel) \
    X_FIELD(NV_ESC_RM_BIND_CONTEXT_DMA, 32, hCtxDma) \
    X_FIELD(NV_ESC_RM_BIND_CONTEXT_DMA, 32, status) \

#define NV_ESC_RM_ADD_VBLANK_CALLBACK(X_ID, X_FIELD)        X_ID(0x56)
#define NV_ESC_RM_EXPORT_OBJECT_TO_FD(X_ID, X_FIELD)        X_ID(0x5C)
#define NV_ESC_RM_IMPORT_OBJECT_FROM_FD(X_ID, X_FIELD)      X_ID(0x5D)
#define NV_ESC_RM_UPDATE_DEVICE_MAPPING_INFO(X_ID, X_FIELD) X_ID(0x5E)
#define NV_ESC_RM_LOCKLESS_DIAGNOSTIC(X_ID, X_FIELD)        X_ID(0x5F)
#define NV_ESC_CARD_INFO(X_ID, X_FIELD)                     X_ID(0xC8)
#define NV_ESC_REGISTER_FD(X_ID, X_FIELD)                   X_ID(0xC9)
#define NV_ESC_ALLOC_OS_EVENT(X_ID, X_FIELD)                X_ID(0xCE)
#define NV_ESC_FREE_OS_EVENT(X_ID, X_FIELD)                 X_ID(0xCF)
#define NV_ESC_STATUS_CODE(X_ID, X_FIELD)                   X_ID(0xD1)
#define NV_ESC_CHECK_VERSION_STR(X_ID, X_FIELD)             X_ID(0xD2)
#define NV_ESC_IOCTL_XFER_CMD(X_ID, X_FIELD)                X_ID(0xD3)
#define NV_ESC_ATTACH_GPUS_TO_FD(X_ID, X_FIELD)             X_ID(0xD4)
#define NV_ESC_QUERY_DEVICE_INTR(X_ID, X_FIELD)             X_ID(0xD5)
#define NV_ESC_SYS_PARAMS(X_ID, X_FIELD)                    X_ID(0xD6)
#define NV_ESC_NUMA_INFO(X_ID, X_FIELD)                     X_ID(0xD7)
#define NV_ESC_SET_NUMA_STATUS(X_ID, X_FIELD)               X_ID(0xD8)
#define NV_ESC_EXPORT_TO_DMABUF_FD(X_ID, X_FIELD)           X_ID(0xD9)

#define FOR_EACH_IOCTL(X) \
    X(NV_ESC_RM_ALLOC_MEMORY) \
    X(NV_ESC_RM_ALLOC_OBJECT) \
    X(NV_ESC_RM_FREE) \
    X(NV_ESC_RM_CONTROL) \
    X(NV_ESC_RM_ALLOC) \
    X(NV_ESC_RM_DUP_OBJECT) \
    X(NV_ESC_RM_SHARE) \
    X(NV_ESC_RM_I2C_ACCESS) \
    X(NV_ESC_RM_IDLE_CHANNELS) \
    X(NV_ESC_RM_VID_HEAP_CONTROL) \
    X(NV_ESC_RM_ACCESS_REGISTRY) \
    X(NV_ESC_RM_MAP_MEMORY) \
    X(NV_ESC_RM_UNMAP_MEMORY) \
    X(NV_ESC_RM_GET_EVENT_DATA) \
    X(NV_ESC_RM_ALLOC_CONTEXT_DMA2) \
    X(NV_ESC_RM_MAP_MEMORY_DMA) \
    X(NV_ESC_RM_UNMAP_MEMORY_DMA) \
    X(NV_ESC_RM_BIND_CONTEXT_DMA) \
    X(NV_ESC_RM_ADD_VBLANK_CALLBACK) \
    X(NV_ESC_RM_EXPORT_OBJECT_TO_FD) \
    X(NV_ESC_RM_IMPORT_OBJECT_FROM_FD) \
    X(NV_ESC_RM_UPDATE_DEVICE_MAPPING_INFO) \
    X(NV_ESC_RM_LOCKLESS_DIAGNOSTIC) \
    X(NV_ESC_CARD_INFO) \
    X(NV_ESC_REGISTER_FD) \
    X(NV_ESC_ALLOC_OS_EVENT) \
    X(NV_ESC_FREE_OS_EVENT) \
    X(NV_ESC_STATUS_CODE) \
    X(NV_ESC_CHECK_VERSION_STR) \
    X(NV_ESC_IOCTL_XFER_CMD) \
    X(NV_ESC_ATTACH_GPUS_TO_FD) \
    X(NV_ESC_QUERY_DEVICE_INTR) \
    X(NV_ESC_SYS_PARAMS) \
    X(NV_ESC_NUMA_INFO) \
    X(NV_ESC_SET_NUMA_STATUS) \
    X(NV_ESC_EXPORT_TO_DMABUF_FD) \


#define ID(x) x(EXPAND, DISCARD)

#define DEFINE_PARAM_STRUCT(name) \
    struct PARAMS_##name { name(DISCARD, DEF_FIELD) };

FOR_EACH_IOCTL(DEFINE_PARAM_STRUCT)

#if IS_VERSION_OR_ABOVE(555,58,02)
#define RPC_HISTORY_DEPTH 128
#else
#define RPC_HISTORY_DEPTH 8
#endif
#if IS_VERSION_OR_ABOVE(565,57,01)
#define HAVE_RUSD 1
#else
#define HAVE_RUSD 0
#endif

#if IS_VERSION(555,42,02)
#define OFFSET_OBJSYS_pGpuMgr 496
#define OFFSET_OBJGPUMGR_gpuHandleIDList 255568
#define OFFSET_OBJGPU_pKernelGsp 5816
#define OFFSET_KernelGsp_pRpc 2920
#define OFFSET_OBJRPC_rpcHistory 1168
#elif IS_VERSION(555,58,02)
#define OFFSET_OBJSYS_pGpuMgr 496
#define OFFSET_OBJGPUMGR_gpuHandleIDList 255568
#define OFFSET_OBJGPU_pKernelGsp 5816
#define OFFSET_KernelGsp_pRpc 2920
#define OFFSET_OBJRPC_rpcHistory 1168
#elif IS_VERSION(560,28,03)
#define OFFSET_OBJSYS_pGpuMgr 488
#define OFFSET_OBJGPUMGR_gpuHandleIDList 255568
#define OFFSET_OBJGPU_pKernelGsp 6024
#define OFFSET_KernelGsp_pRpc 2920
#define OFFSET_OBJRPC_rpcHistory 1184
#elif IS_VERSION(565,57,01)
#define OFFSET_OBJSYS_pGpuMgr 488
#define OFFSET_OBJGPUMGR_gpuHandleIDList 257360
#define OFFSET_OBJGPU_pKernelGsp 6168
#define OFFSET_KernelGsp_pRpc 2344
#define OFFSET_OBJRPC_rpcHistory 1192
#define OFFSET_OBJGPU_userSharedData 14472
#elif IS_VERSION(570,124,04) || IS_VERSION(570,124,06)
#define OFFSET_OBJSYS_pGpuMgr 480
#define OFFSET_OBJGPUMGR_gpuHandleIDList 257360
#define OFFSET_OBJGPU_pKernelGsp 6216
#define OFFSET_KernelGsp_pRpc 2368
#define OFFSET_OBJRPC_rpcHistory 1272
#define OFFSET_OBJGPU_userSharedData 14576
#else
#error "Unknown driver version"
#endif


// Minimal structure definitions to get the RPC history
struct OBJSYS {
    char pad[OFFSET_OBJSYS_pGpuMgr];
    struct OBJGPUMGR* pGpuMgr;
};
struct OBJGPUMGR {
    char pad[OFFSET_OBJGPUMGR_gpuHandleIDList];
    struct {
        struct OBJGPU *pGpu;
        unsigned int gpuInstance;
    } gpuHandleIDList[32];
};
struct OBJGPU {
    char pad[OFFSET_OBJGPU_pKernelGsp];
    struct KernelGsp* pKernelGsp;
    char pad2[OFFSET_OBJGPU_userSharedData - OFFSET_OBJGPU_pKernelGsp - sizeof(struct KernelGsp*)];
    struct {
        void *pMemDesc;
        struct NV00DE_SHARED_DATA* pMapBuffer;
        unsigned long lastPolledDataMask;
        // ...
    } userSharedData;
};
struct KernelGsp {
    char pad[OFFSET_KernelGsp_pRpc];
    struct OBJRPC* pRpc;
};
struct RpcHistoryEntry {
    unsigned function;
    unsigned long data[2];
    unsigned long ts_start;
    unsigned long ts_end;
};
struct OBJRPC {
    char pad[OFFSET_OBJRPC_rpcHistory];
    struct RpcHistoryEntry rpcHistory[RPC_HISTORY_DEPTH];
    unsigned rpcHistoryCurrent;
};


struct NV00DE_SHARED_DATA {
    struct /*RUSD_BAR1_MEMORY_INFO*/ {
        unsigned long long lastModifiedTimestamp;
        unsigned bar1Size;
        unsigned bar1AvailSize;
    } bar1MemoryInfo;

    struct /*RUSD_PMA_MEMORY_INFO*/ {
        unsigned long long lastModifiedTimestamp;
        unsigned long long totalPmaMemory;
        unsigned long long freePmaMemory;
    } pmaMemoryInfo;

    struct /*RUSD_SHADOW_ERR_CONT*/ {
        unsigned long long lastModifiedTimestamp;
        unsigned shadowErrContVal;
    } shadowErrCont;

    struct /*RUSD_GR_INFO*/ {
        unsigned long long lastModifiedTimestamp;
        char bCtxswLoggingEnabled;
    } grInfo;

    struct /*RUSD_CLK_PUBLIC_DOMAIN_INFOS*/{
        unsigned long long lastModifiedTimestamp;
        struct {
            unsigned targetClkMHz;
        } info[4];
    } clkPublicDomainInfos;

    struct /*RUSD_CLK_THROTTLE_REASON*/ {
        unsigned long long lastModifiedTimestamp;
        unsigned reasonMask;
    } clkThrottleReason;

    struct /*RUSD_PERF_DEVICE_UTILIZATION*/ {
        unsigned long long lastModifiedTimestamp;
        struct{
            unsigned gpuPercentBusy;
            unsigned memoryPercentBusy;
            struct {
                unsigned clkPercentBusy;
                unsigned samplingPeriodUs;
            } engUtil[4];
        } info;
    } perfDevUtil;

    struct /*RUSD_MEM_ECC*/ {
        unsigned long long lastModifiedTimestamp;
        struct{
            unsigned long long correctedVolatile;
            unsigned long long correctedAggregate;
            unsigned long long uncorrectedVolatile;
            unsigned long long uncorrectedAggregate;
        } count[3];
    } memEcc;

    struct /*RUSD_PERF_CURRENT_PSTATE*/ {
        unsigned long long lastModifiedTimestamp;
        unsigned currentPstate;
    } perfCurrentPstate;

    struct /*RUSD_POWER_LIMITS*/ {
        unsigned long long lastModifiedTimestamp;
        struct{
            unsigned requestedmW;
            unsigned enforcedmW;
        } info;
    } powerLimitGpu;

#if IS_VERSION_OR_ABOVE(570,124,04)
    struct /*RUSD_TEMPERATURE*/ {
        unsigned long long lastModifiedTimestamp;
        signed temperature;
    } temperature[2];
#else
    struct /*RUSD_TEMPERATURE*/ {
        unsigned long long lastModifiedTimestamp;
        struct{
            signed gpuTemperature;
            signed hbmTemperature;
        } info;
    } temperature;
#endif
    struct /*RUSD_MEM_ROW_REMAP*/ {
        unsigned long long lastModifiedTimestamp;
        struct{
            unsigned histogramMax;
            unsigned histogramHigh;
            unsigned histogramPartial;
            unsigned histogramLow;
            unsigned histogramNone;

            unsigned correctableRows;
            unsigned uncorrectableRows;
            char isPending;
            char hasFailureOccurred;
        } info;
    } memRowRemap;

    struct /*RUSD_AVG_POWER_USAGE*/ {
        unsigned long long lastModifiedTimestamp;
        struct{
            unsigned averageGpuPower;
            unsigned averageModulePower;
            unsigned averageMemoryPower;
        } info;
    } avgPowerUsage;

    struct /*RUSD_INST_POWER_USAGE*/ {
        unsigned long long lastModifiedTimestamp;
        struct {
            unsigned instGpuPower;
            unsigned instModulePower;
            unsigned instCpuPower;
        } info;
    } instPowerUsage;

    struct /*RUSD_PCIE_DATA*/ {
        unsigned long long lastModifiedTimestamp;
        struct {
            unsigned data[9];
        } info;
    } pciBusData;
};
#define USEC(ns) ((ns) / (uint64)1000)
#define MSEC(ns) ((ns) / (uint64)1000000)
#define SEC(ns)  ((ns) / (uint64)1000000000)

#define DECL_TIMESTAMPS()                                 \
    $now = (uint64)nsecs(monotonic);                      \
    $ts_sec = SEC($now);                                  \
    $ts_usec = USEC($now % 1000000000);                   \
    $elapsed_nsec = $now - @entrytime[tid];


#define PRINT(text, num) \
    printf("%s[%d.%d][%s:%d] %s (0x%x) %lldus%s\n", \
        USEC($elapsed_nsec) > WARNTIME ? COLOR_BOLD : "", \
        $ts_sec, $ts_usec, comm, pid, text, num, USEC($elapsed_nsec), \
        USEC($elapsed_nsec) > WARNTIME ? COLOR_RESET : ""); \


#define INIT_ENTRY_ARGS(ctrl, ptr)                      \
    $ctl = ctrl;                                        \
    if (FILTER) {                                       \
        @entryctl[tid] = $ctl;                          \
        @entryptr[tid] = uptr(ptr);                     \
        @entrytime[tid] = (uint64)nsecs(monotonic);     \
    }

#define CLEAR_ENTRY_ARGS()  \
    delete(@entryctl[tid]); \
    delete(@entryptr[tid]); \
    delete(@entrytime[tid]); \



#define PRINT_RPC_HISTORY() \
  if (1) { \
    $i = (uint32)0; \
    while ($i < RPC_HISTORY_DEPTH) { \
        $idx = (@pRpc->rpcHistoryCurrent + RPC_HISTORY_DEPTH - $i) % RPC_HISTORY_DEPTH; \
        $rpcHistoryAddr = (uint8*)@pRpc + OFFSET_OBJRPC_rpcHistory; \
        $entry = (struct RpcHistoryEntry*)($rpcHistoryAddr + $idx * sizeof(struct RpcHistoryEntry)); \
                                                                                                     \
        printf("[RPC:%d] func:0x%x data:0x%lx 0x%lx ts_start:%lu ts_end:%lu, duration:%lu\n", \
            $idx, $entry->function, $entry->data[0], $entry->data[1], $entry->ts_start, $entry->ts_end, $entry->ts_end - $entry->ts_start); \
        $i++; \
    } \
  }

config = {
//    max_strlen=64;
    missing_probes = "ignore";
    perf_rb_pages = 256;
    log_size = 10000000;
}

BEGIN {
    @lastprint_nsec = nsecs;

    // https://github.com/bpftrace/bpftrace/issues/3294
    #define MAKE_IOCTL_NAME(IOCTLNAME) \
        @ioctlnames[ID(IOCTLNAME)] = #IOCTLNAME;
    FOR_EACH_IOCTL(MAKE_IOCTL_NAME)

    // Init to define the map key/value types
    @ioctls[0,0] = ((uint64)0, (uint64)0, (uint64)0);

    // Only single-GPU supported for now...
    $pSys = kptr(*(struct OBJSYS**)kptr(ADDR_PSYS));
    @pGpu = $pSys->pGpuMgr->gpuHandleIDList[0].pGpu;
    @pRpc = @pGpu->pKernelGsp->pRpc;

    PRINT_RPC_HISTORY()    

    @rusd = @pGpu->userSharedData.pMapBuffer;
}

kprobe:nvidia_unlocked_ioctl {
    INIT_ENTRY_ARGS(arg1 & 0xff, arg2)
}

kretprobe:nvidia_unlocked_ioctl / @entrytime[tid] / {
    DECL_TIMESTAMPS()
    $ctl = @entryctl[tid];
    $ptr = @entryptr[tid];

    $sub = 0;
    if ($ctl == ID(NV_ESC_RM_CONTROL)) {
        $sub = ((struct PARAMS_NV_ESC_RM_CONTROL *)$ptr)->cmd;
    } else if ($ctl == ID(NV_ESC_RM_ALLOC)) {
        $sub = ((struct PARAMS_NV_ESC_RM_ALLOC *)$ptr)->hClass;
    }

    $unknown = 1;

    $x = @ioctls[$ctl, $sub];
    $count = $x.0 + 1;
    $dursum = $elapsed_nsec + $x.1;
    $durmax = ($x.2 > $elapsed_nsec) ? $x.2 : $elapsed_nsec;

    @ioctls[$ctl, $sub] = ($count, $dursum, $durmax);

    if (USEC($elapsed_nsec) >= MINTIME) {
        #define HANDLE_IOCTL(IOCTLNAME)             \
            if ($ctl == ID(IOCTLNAME))              \
            {                                       \
                PRINT(#IOCTLNAME, $ctl)             \
                printf("    %s", COLOR_DIM);        \
                IOCTLNAME(DISCARD, PRINT_FIELD)     \
                printf("%s\n", COLOR_RESET);        \
                $unknown = 0;                       \
            } else
        FOR_EACH_IOCTL(HANDLE_IOCTL)

        if ($unknown == 1) {
            PRINT("UNKNWON", $ctl)
        }
    }
    CLEAR_ENTRY_ARGS()
}


#define SIMPLE_ENTRYPOINT(funcname)             \
     kprobe:funcname {                          \
         INIT_ENTRY_ARGS(0, 0)                  \
     }                                          \
     kretprobe:funcname / @entrytime[tid] / {   \
         DECL_TIMESTAMPS()                      \
         PRINT(#funcname, 0)                    \
         CLEAR_ENTRY_ARGS()                     \
     }

SIMPLE_ENTRYPOINT(nvidia_mmap)
SIMPLE_ENTRYPOINT(nvidia_open)
SIMPLE_ENTRYPOINT(nvidia_close)
//SIMPLE_ENTRYPOINT(nvidia_poll) // way too spammy

// Only fire on ALT key down
#define L_ALT 56
#define R_ALT 100
kprobe:input_event / arg1==1 && (arg2==L_ALT || arg2==R_ALT) && arg3 == 1 / {
    $now = nsecs;
    if (MSEC($now - @last_alt_keydown) < 200) {
        printf("%s!!! POINT OF INTEREST !!!%s\n", COLOR_BOLD, COLOR_RESET);         
        PRINT_RPC_HISTORY()
    }
    @last_alt_keydown = $now;
}

#if HAVE_RUSD
#define PRINT_RUSD_VAL_IF_CHANGED_BASE(grp, field, fmt) \
    if (@rusd->grp.lastModifiedTimestamp != 0) { \
        if (!@rusd_last_val[#field]) { \
            @rusd_last_val[#field] = (uint64)0; \
        } \
        $curr = (uint64)@rusd->grp.field; \
        $last = (uint64)@rusd_last_val[#field]; \
        if ($last != $curr) { \
            printf(fmt, #grp, #field, $last, $curr); \
            @rusd_last_val[#field] = $curr; \
        } \
    }

#define PRINT_RUSD_VAL_IF_CHANGED_DEC(grp, field) \
    PRINT_RUSD_VAL_IF_CHANGED_BASE(grp, field, "[RUSD] %s.%s change: %llu -> %llu\n")

#define PRINT_RUSD_VAL_IF_CHANGED_HEX(grp, field) \
    PRINT_RUSD_VAL_IF_CHANGED_BASE(grp, field, "[RUSD] %s.%s change: 0x%llx -> 0x%llx\n")

interval:ms:500 {
    PRINT_RUSD_VAL_IF_CHANGED_HEX(perfCurrentPstate, currentPstate)
    PRINT_RUSD_VAL_IF_CHANGED_HEX(clkThrottleReason, reasonMask)

    PRINT_RUSD_VAL_IF_CHANGED_DEC(bar1MemoryInfo, bar1AvailSize)
    PRINT_RUSD_VAL_IF_CHANGED_DEC(perfDevUtil, info.gpuPercentBusy)
    PRINT_RUSD_VAL_IF_CHANGED_DEC(perfDevUtil, info.memoryPercentBusy)
}
#endif // HAVE_RUSD

END {
    $end_start = nsecs;
    printf("Stopped tracing..\n");
    printf("%30s | %10s | %5s | %10s | %8s |\n",
        "ioctl", "cmd", "count", "total exec", "max exec");
    printf("-------------------------------|------------|-------|------------|----------|\n");

    @last_max_val = (uint64)0xffffffffffffffff;
    for ($tmp : @ioctls) {
        @max_val = (uint64)0;
        for ($kv : @ioctls) {
            if (($kv.1.1 > @max_val) && ($kv.1.1 < @last_max_val) && ($kv.0 != @max_key)) {
                @max_val = $kv.1.1;
                @max_key = $kv.0;
            }
        }
        if ((@max_key.0 != @last_max_key.0) || (@max_key.1 != @last_max_key.1)) {
            $ctl = @max_key.0;
            $sub = @max_key.1;

            $count = @ioctls[$ctl, $sub].0;
            $dursum = @ioctls[$ctl, $sub].1;
            $durmax = @ioctls[$ctl, $sub].2;

            printf("%30s | 0x%08x | %5lld | %10lld | %8lld |\n",
                @ioctlnames[$ctl], $sub, $count, USEC($dursum), USEC($durmax));
            @last_max_val = @max_val;
            @last_max_key = @max_key;
        }
    }
    printf("-------------------------------|------------|-------|------------|----------|\n");
    printf("Report finished in %llu us\n", USEC(nsecs - $end_start));

    clear(@ioctls);

    clear(@entryctl);
    clear(@entryptr);
    clear(@entrytime);
    clear(@ioctlnames);
    delete(@lastprint_nsec);
    delete(@last_max_val);
    delete(@last_max_key);
    delete(@max_key);
    delete(@max_val);
    PRINT_RPC_HISTORY()    
}


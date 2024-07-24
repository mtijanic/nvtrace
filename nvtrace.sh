#!/bin/sh

echo "nvtrace performance and stutter diagnostics tool, version 0.1"
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

# TODO: Only supported on OpenRM for now. Need to divine the offsets for the proprietary driver.
nvidia_license=$(modinfo nvidia | grep license | awk '{$1=""; print}')
if [ "$nvidia_license" != " Dual MIT/GPL" ]; then
    echo "ERROR: nvtrace only works with the Open Source NVIDIA GPU kernel modules"
    exit 1
fi

echo "Running nvidia-bug-report.sh, this may take a minute..."
sudo nvidia-bug-report.sh --output-file $outdir/nvidia-bug-report-start.log > /dev/null

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

# Get the structure offsets for the current NVIDIA driver version

rpc_history_depth=128

case "$nvidia_version" in
    "555.42.02")
        offsets=" \
-DOFFSET_OBJSYS_pGpuMgr=496 \
-DOFFSET_OBJGPUMGR_gpuHandleIDList=255568 \
-DOFFSET_OBJGPU_pKernelGsp=5816 \
-DOFFSET_KernelGsp_pRpc=2920 \
-DOFFSET_OBJRPC_rpcHistory=1168"
        # This was extended to 128 later in r555
        rpc_history_depth=8
        ;;
    "555.58.02")
        offsets=" \
-DOFFSET_OBJSYS_pGpuMgr=496 \
-DOFFSET_OBJGPUMGR_gpuHandleIDList=255568 \
-DOFFSET_OBJGPU_pKernelGsp=5816 \
-DOFFSET_KernelGsp_pRpc=2920 \
-DOFFSET_OBJRPC_rpcHistory=1168"
        ;;
    "560.28.03")
        offsets=" \
-DOFFSET_OBJSYS_pGpuMgr=488 \
-DOFFSET_OBJGPUMGR_gpuHandleIDList=255568 \
-DOFFSET_OBJGPU_pKernelGsp=6024 \
-DOFFSET_KernelGsp_pRpc=2920 \
-DOFFSET_OBJRPC_rpcHistory=1184"
        ;;
    *)
        echo "ERROR: Unknown NVIDIA driver version $nvidia_version"
        exit 1
        ;;
esac


gpsys=$(sudo grep g_pSys /proc/kallsyms | awk '{print $1}' | xargs printf "0x%s")
ctrl_c() {
    echo ""
    echo "CTRL+C received, stopping trace.."
    echo ""
    sudo killall -s INT nvt-bpftrace
}

trap ctrl_c INT

# Preprocess and then run the bpftrace script..

CPPFLAGS="$offsets -DADDR_PSYS=$gpsys -DRPC_HISTORY_DEPTH=$rpc_history_depth"

echo "Starting bpftrace.."

# bpftrace will be stopped by ctrl_c() trap handler
grep --after-context=9999999 'BEGIN[_]BPFTRACE[_]SCRIPT' $0 | cpp -P $CPPFLAGS $* - | xargs -0 sudo ./nvt-bpftrace -e  > $outdir/bpftrace.log &

# Display output to user too
tail -f $outdir/bpftrace.log
sleep 2
echo ""
echo "Will collect trace end system state"
echo "Running nvidia-bug-report.sh, this may take a minute..."
echo ""
sudo nvidia-bug-report.sh --output-file $outdir/nvidia-bug-report-end.log > /dev/null
# Tar up everything in outdir and copy to pwd

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

echo ""
echo "By delivering this file to NVIDIA, you acknowledge"
echo "and agree that personal information may inadvertently be included in"
echo "the output.  Notwithstanding the foregoing, NVIDIA will use the"
echo "output only for the purpose of investigating your reported issue."
echo ""
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

// Minimal structure definitions to get the RPC history
struct OBJSYS {
    char pad[OFFSET_OBJSYS_pGpuMgr];
    struct OBJGPUMGR* pGpuMgr;
};
struct GPU_HANDLE_ID {
    struct OBJGPU *pGpu;
    unsigned int gpuInstance;
}
struct OBJGPUMGR {
    char pad[OFFSET_OBJGPUMGR_gpuHandleIDList];
    struct GPU_HANDLE_ID gpuHandleIDList[32];
};
struct OBJGPU {
    char pad[OFFSET_OBJGPU_pKernelGsp];
    struct KernelGsp* pKernelGsp;
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


# Get the structure offsets for the current NVIDIA driver version

case "$nvidia_version" in
    "555.42.02")
        offsets=" \
-DOFFSET_OBJSYS_pGpuMgr=496 \
-DOFFSET_OBJGPUMGR_gpuHandleIDList=255568 \
-DOFFSET_OBJGPU_pKernelGsp=5816 \
-DOFFSET_KernelGsp_pRpc=2920 \
-DOFFSET_OBJRPC_rpcHistory=1168"
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
    "565.57.01")
        offsets=" \
-DOFFSET_OBJSYS_pGpuMgr=488 \
-DOFFSET_OBJGPUMGR_gpuHandleIDList=257360 \
-DOFFSET_OBJGPU_pKernelGsp=6168 \
-DOFFSET_KernelGsp_pRpc=2344 \
-DOFFSET_OBJRPC_rpcHistory=1192"
        ;;
    "570.124.04"|"570.124.06")
        offsets=" \
-DOFFSET_OBJSYS_pGpuMgr=480 \
-DOFFSET_OBJGPUMGR_gpuHandleIDList=257360 \
-DOFFSET_OBJGPU_pKernelGsp=6216 \
-DOFFSET_KernelGsp_pRpc=2368 \
-DOFFSET_OBJRPC_rpcHistory=1272"
        ;;
    *)
        echo "ERROR: Unknown NVIDIA driver version $nvidia_version"
        exit 1
        ;;
esac


gpsys=$(sudo grep g_pSys /proc/kallsyms | awk '{print $1}' | xargs printf "0x%s")

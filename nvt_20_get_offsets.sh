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
        rpc_history_depth=8
        ;;
    *)
        echo "Unknown NVIDIA driver version $nvidia_version"
        exit 1
        ;;
esac

gpsys=$(sudo grep g_pSys /proc/kallsyms | awk '{print $1}' | xargs printf "0x%s")

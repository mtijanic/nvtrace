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


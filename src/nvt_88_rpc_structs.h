#if IS_VERSION_OR_ABOVE(555,58,02)
#define RPC_HISTORY_DEPTH 128
#else
#define RPC_HISTORY_DEPTH 8
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
#elif IS_VERSION(570,124,04) || IS_VERSION(570,124,06)
#define OFFSET_OBJSYS_pGpuMgr 480
#define OFFSET_OBJGPUMGR_gpuHandleIDList 257360
#define OFFSET_OBJGPU_pKernelGsp 6216
#define OFFSET_KernelGsp_pRpc 2368
#define OFFSET_OBJRPC_rpcHistory 1272
#else
#error "Unknown driver version"
#endif


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


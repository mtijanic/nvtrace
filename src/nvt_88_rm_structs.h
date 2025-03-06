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

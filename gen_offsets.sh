#!/bin/sh
OGKM=$1
if [ -z "$OGKM" ]; then
    echo "Usage: $0 <path to open-gpu-kernel-modules>"
    exit 1
fi

INCLUDES="-I$OGKM/src/nvidia/kernel/inc  \
-I$OGKM/src/nvidia/interface  \
-I$OGKM/src/common/sdk/nvidia/inc  \
-I$OGKM/src/common/sdk/nvidia/inc/hw  \
-I$OGKM/src/nvidia/arch/nvalloc/common/inc  \
-I$OGKM/src/nvidia/arch/nvalloc/common/inc/gsp  \
-I$OGKM/src/nvidia/arch/nvalloc/common/inc/deprecated  \
-I$OGKM/src/nvidia/arch/nvalloc/unix/include  \
-I$OGKM/src/nvidia/inc  \
-I$OGKM/src/nvidia/inc/os  \
-I$OGKM/src/common/shared/inc  \
-I$OGKM/src/common/shared/msgq/inc  \
-I$OGKM/src/common/inc  \
-I$OGKM/src/common/uproc/os/libos-v2.0.0/include  \
-I$OGKM/src/common/uproc/os/common/include  \
-I$OGKM/src/common/inc/swref  \
-I$OGKM/src/common/inc/swref/published  \
-I$OGKM/src/nvidia/generated  \
-I$OGKM/src/common/nvswitch/kernel/inc \
-I$OGKM/src/common/nvswitch/interface \
-I$OGKM/src/common/nvswitch/common/inc \
-I$OGKM/src/common/inc/displayport \
-I$OGKM/src/common/nvlink/interface \
-I$OGKM/src/common/nvlink/inband/interface \
-I$OGKM/src/mm/uvm/interface \
-I$OGKM/src/nvidia/inc/libraries  \
-I$OGKM/src/nvidia/src/libraries  \
-I$OGKM/src/nvidia/inc/kernel"

DEFINES="-D_LANGUAGE_C  \
-D__NO_CTYPE  \
-DNVRM  \
-DLOCK_VAL_ENABLED=0  \
-DPORT_ATOMIC_64_BIT_SUPPORTED=1  \
-DPORT_IS_KERNEL_BUILD=1  \
-DPORT_IS_CHECKED_BUILD=1  \
-DPORT_MODULE_atomic=1  \
-DPORT_MODULE_core=1  \
-DPORT_MODULE_cpu=1  \
-DPORT_MODULE_crypto=1  \
-DPORT_MODULE_debug=1  \
-DPORT_MODULE_memory=1  \
-DPORT_MODULE_safe=1  \
-DPORT_MODULE_string=1  \
-DPORT_MODULE_sync=1  \
-DPORT_MODULE_thread=1  \
-DPORT_MODULE_util=1  \
-DPORT_MODULE_example=0  \
-DPORT_MODULE_mmio=0  \
-DPORT_MODULE_time=0  \
-DRS_STANDALONE=0  \
-DRS_STANDALONE_TEST=0  \
-DRS_COMPATABILITY_MODE=1  \
-DRS_PROVIDES_API_STATE=0  \
-DNV_CONTAINERS_NO_TEMPLATES  \
-DINCLUDE_NVLINK_LIB  \
-DINCLUDE_NVSWITCH_LIB  \
-DNV_PRINTF_STRINGS_ALLOWED=1  \
-DNV_ASSERT_FAILED_USES_STRINGS=1  \
-DPORT_ASSERT_FAILED_USES_STRINGS=1"

CPPFLAGS="$INCLUDES $DEFINES -include $OGKM/src/common/sdk/nvidia/inc/cpuopsys.h"
CFLAGS="-Wint-conversion -Wno-unused-variable -O2 -ffreestanding"

grep "kernel_open.html" < $OGKM/README.md

cc $CPPFLAGS $CFLAGS -x c - > /dev/null << \EOF

#include "core/system.h"
#include "gpu/gpu.h"
#include "gpu_mgr/gpu_mgr.h"
#include "gpu/gsp/kernel_gsp.h"
#include "gpu/rpc/objrpc.h"

#define PRINT_OFFSETOF(name, A, B) \
    void name() { char (*name##_)[sizeof(char[offsetof(A, B)])] = 1; }

PRINT_OFFSETOF(OFFSET_OBJSYS_pGpuMgr, OBJSYS, pGpuMgr)
PRINT_OFFSETOF(OFFSET_OBJGPUMGR_gpuHandleIDList, OBJGPUMGR, gpuHandleIDList)
PRINT_OFFSETOF(OFFSET_OBJGPU_pKernelGsp, OBJGPU, children.named.pKernelGsp)
PRINT_OFFSETOF(OFFSET_KernelGsp_pRpc, KernelGsp, pRpc)
PRINT_OFFSETOF(OFFSET_OBJRPC_rpcHistory, OBJRPC, rpcHistory)

EOF
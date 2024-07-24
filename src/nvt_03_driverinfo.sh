
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


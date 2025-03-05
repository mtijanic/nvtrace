
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


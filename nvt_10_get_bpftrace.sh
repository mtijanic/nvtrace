
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


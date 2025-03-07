ctrl_c() {
    echo ""
    echo "CTRL+C received, stopping trace.."
    echo ""
    sudo killall -s INT nvt-bpftrace
    sudo killall -s INT nvt-rmcfg
}

trap ctrl_c INT


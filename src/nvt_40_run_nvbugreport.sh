if [ -z "$trace_only" ]; then
    echo ""
    echo "Will collect trace end system state"
    echo "Running nvidia-bug-report.sh, this may take a minute..."
    echo ""
    sudo nvidia-bug-report.sh --output-file $outdir/nvidia-bug-report-end.log > /dev/null
fi

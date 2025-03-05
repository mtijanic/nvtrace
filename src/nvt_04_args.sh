trace_only=
for arg in "$@"; do
    if [ "$arg" = "--trace-only" ]; then
        trace_only=1
        echo "Running in trace-only mode"
        shift
        break
    fi
done

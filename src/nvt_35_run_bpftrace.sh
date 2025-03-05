# Preprocess and then run the bpftrace script..

CPPFLAGS="$offsets -DADDR_PSYS=$gpsys \
-DVER_MAJOR=$ver_major -DVER_MINOR=$ver_minor -DVER_PATCH=$ver_patch"

echo "Starting bpftrace.."

# bpftrace will be stopped by ctrl_c() trap handler
grep --after-context=9999999 'BEGIN[_]BPFTRACE[_]SCRIPT' $0 | cpp -P $CPPFLAGS $* - | xargs -0 sudo ./nvt-bpftrace -e  > $outdir/bpftrace.log &

# Display output to user too
tail -f $outdir/bpftrace.log
sleep 2

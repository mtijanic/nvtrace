EOF
# ^ end the cat started in rmcfg_pre.sh

gcc -o $outdir/nvt-rmcfg \
    -DVER_MAJOR=$ver_major -DVER_MINOR=$ver_minor -DVER_PATCH=$ver_patch \
    $outdir/rmcfg.c

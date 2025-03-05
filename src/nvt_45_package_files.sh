# Tar up everything in outdir and copy to pwd

if [ -z "$trace_only" ]; then
    tarname=nvtrace-$(date +%Y%m%d%H%M%S).tar.gz

    #tar -czf $tarname $outdir/*
    oldpwd=$(pwd)
    cd $outdir
    tar -czf $oldpwd/$tarname *
    cd $oldpwd


    echo ""
    echo "Saved trace output to $tarname"
    echo "Please send this file to mtijanic@nvidia.com for analysis."
    echo ""
fi


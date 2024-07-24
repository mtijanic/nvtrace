# nvtrace

A performance and stutter analysis tool for NVIDIA Open GPU Kernel modules

# How to use

Simply download and run `nvtrace.sh` (requires root permissions).

If you notice stutter or performance issues, double-tap the ALT key to insert a "point of interest" where we should investigate more. This will also dump more relevant info around that point.

To stop tracing, press CTRL+C. This will then package up all the log files and put then in the pwd. You can then send this `nvtrace-xxx.tar.gz` file to NVIDIA.

# Private info

`nvtrace.sh` uses `nvidia-bug-report.sh` to capture system state, and it may include some private info. The disclaimer from `nvidia-bug-report.sh` applies:

    By delivering 'nvidia-bug-report.log.gz' to NVIDIA, you acknowledge
    and agree that personal information may inadvertently be included in
    the output.  Notwithstanding the foregoing, NVIDIA will use the
    output only for the purpose of investigating your reported issue.

# Modifying nvtrace

The script consists of a bunch of smaller fragments found in `src/`. 

To produce the full runnable nvtrace.sh, run:

```
cat src/nvt_* > nvtrace.sh
```

# Supported driver versions

The tool currently only supports Open GPU Kernel Modules (nvidia-open) drivers.

Supported driver versions:

- 555.42.02
- 555.58.02
- 560.28.03


# bpftrace

The core of `nvtrace.sh` is the wonderful https://github.com/bpftrace/bpftrace tool. Because this tool is under active development, and most distros ship an outdated version, `nvtrace.sh` will download a recent known good version instead and run it out of pwd.

# TODOs

- More info around GSP RPCs (attach comm:pid, human readable enums)
- Handle multi-GPU (currently only single GPU systems work reliably)
- Improve script robustness and portability
- Don't download bpftrace when not necessary
- Make it work on closed source driver too
- Add RmMsg calls to enable more verbose prints from nvidia.ko
- Log nvidia_drm.ko and nvidia_modeset.ko calls
- Configurable options (customizable keybind for ALT)

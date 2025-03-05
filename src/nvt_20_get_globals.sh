# Get the address of global variables
gpsys=$(sudo grep g_pSys /proc/kallsyms | awk '{print $1}' | xargs printf "0x%s")

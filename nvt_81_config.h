//
// CONFIG - pass as -DFOO=1 to the script
//

// Minimum duration (in usec) of an ioctl before it can be logged. 0: log all
#ifndef MINTIME
#define MINTIME 0
#endif

// Duration (in usec) above which the print will be highlighted
#ifndef WARNTIME
#define WARNTIME 1000
#endif

// You can optionally pass a FILTER for when to profile, some examples:
//     '-DFILTER=(comm=="nvidia-smi")'
//     '-DFILTER=(comm!="Xorg"&&comm!="xfwm4")'
//     '-DFILTER=($ctl==0x2A)'
#ifndef FILTER
#define FILTER 1
#endif

#define COLOR_DIM "\033[2m"
#define COLOR_BOLD "\033[1;31m"
#define COLOR_RESET "\033[0m"

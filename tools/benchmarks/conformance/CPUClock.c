#include "Support.h"
#include <mach/mach_time.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

// Exercise the real sampler against an independent process CPU clock. A
// synthetic counter replay cannot catch Mach ticks mislabeled as nanoseconds.
int main(void) {
    BenchProcess before, after;
    if (bench_process(getpid(), &before) != 0) return 1;
    uint64_t start = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID);
    uint64_t deadline = bench_now_ns() + 10000000000ULL;
    volatile unsigned long work = 0;
    while (clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - start < 200000000ULL) {
        for (int i = 0; i < 10000; ++i) work += i;
        if (bench_now_ns() > deadline) return 2;
    }
    uint64_t elapsed = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - start;
    if (bench_process(getpid(), &after) != 0) return 3;
    uint64_t sampled = after.user_ns + after.system_ns - before.user_ns - before.system_ns;
    double ratio = (double)sampled / elapsed;
    mach_timebase_info_data_t timebase;
    if (mach_timebase_info(&timebase) != KERN_SUCCESS) return 4;
    printf("{\"processClockNS\":%llu,\"samplerNS\":%llu,\"ratio\":%.9f,"
           "\"timebaseNumer\":%u,\"timebaseDenom\":%u}\n",
           (unsigned long long)elapsed, (unsigned long long)sampled, ratio,
           timebase.numer, timebase.denom);
    // Allow scheduling/accounting granularity, not a performance score. The
    // unconverted Apple Silicon counter is about 0.024 of the reference.
    return ratio >= .95 && ratio <= 1.05 ? 0 : 5;
}

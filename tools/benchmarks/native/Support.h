#include <stdint.h>
typedef struct {
    int pid, ppid, error;
    uint64_t birth_us, user_ns, system_ns, footprint_bytes;
    char path[4096];
} BenchProcess;
int bench_process(int pid, BenchProcess *result);
int bench_pids(int *buffer, int count);
int bench_watch(int pid);
uint32_t bench_events(int descriptor);
uint64_t bench_now_ns(void);

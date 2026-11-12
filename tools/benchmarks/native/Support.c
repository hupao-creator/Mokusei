#include "Support.h"
#include <libproc.h>
#include <mach/mach_time.h>
#include <sys/event.h>
#include <sys/proc_info.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>

int bench_process(int pid, BenchProcess *r) {
    memset(r, 0, sizeof(*r));
    r->pid = pid;
    struct proc_bsdinfo info = {0};
    struct rusage_info_v4 usage = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) ||
        proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0) {
        r->error = errno;
        return -1;
    }
    r->ppid = info.pbi_ppid;
    r->birth_us = info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec;
    r->user_ns = usage.ri_user_time;
    r->system_ns = usage.ri_system_time;
    r->footprint_bytes = usage.ri_phys_footprint;
    proc_pidpath(pid, r->path, sizeof(r->path));
    return 0;
}
int bench_pids(int *buffer, int count) { return proc_listallpids(buffer, count * sizeof(int)); }
int bench_watch(int pid) {
    int fd = kqueue();
    if (fd < 0) return -1;
    struct kevent e;
    // NOTE_TRACK/NOTE_CHILD are unsupported on Darwin. Fork/exit notes expose
    // accounting gaps; they do not supply descendant identity or exit CPU.
    EV_SET(&e, pid, EVFILT_PROC, EV_ADD | EV_ENABLE | EV_CLEAR,
           NOTE_FORK | NOTE_EXEC | NOTE_EXIT, 0, NULL);
    if (kevent(fd, &e, 1, NULL, 0, NULL) != 0) { close(fd); return -1; }
    return fd;
}
uint32_t bench_events(int fd) {
    struct kevent e;
    struct timespec timeout = {0};
    int n = kevent(fd, NULL, 0, &e, 1, &timeout);
    return n == 1 ? e.fflags : 0;
}
uint64_t bench_now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

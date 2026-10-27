package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type processSample struct {
	PID, PPID, PGID, RSSKiB int
	Command, Started        string
}
type resourceSample struct {
	Cycle        int     `json:"cycle"`
	Seconds      float64 `json:"seconds"`
	RSSKiB       int     `json:"rssKiB"`
	FDs          int     `json:"fds"`
	Descendants  int     `json:"descendants"`
	NativeRSSKiB int     `json:"nativeRSSKiB"`
}

func systemProcesses(ctx context.Context) ([]processSample, error) {
	out, err := exec.CommandContext(ctx, "/bin/ps", "-axo", "pid=,ppid=,pgid=,rss=,lstart=,comm=").Output()
	if err != nil {
		return nil, err
	}
	var rows []processSample
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 10 {
			continue
		}
		nums := make([]int, 4)
		for i := range nums {
			n, e := strconv.Atoi(f[i])
			if e != nil {
				return nil, e
			}
			nums[i] = n
		}
		rows = append(rows, processSample{PID: nums[0], PPID: nums[1], PGID: nums[2], RSSKiB: nums[3], Started: strings.Join(f[4:9], " "), Command: strings.Join(f[9:], " ")})
	}
	return rows, nil
}
func processTree(ctx context.Context, root int) ([]processSample, error) {
	rows, err := systemProcesses(ctx)
	if err != nil {
		return nil, err
	}
	owned := map[int]bool{root: true}
	for changed := true; changed; {
		changed = false
		for _, p := range rows {
			if owned[p.PPID] && !owned[p.PID] {
				owned[p.PID] = true
				changed = true
			}
		}
	}
	var result []processSample
	for _, p := range rows {
		if owned[p.PID] {
			result = append(result, p)
		}
	}
	return result, nil
}
func sampleResources(ctx context.Context, pid, cycle int, elapsed time.Duration) (resourceSample, error) {
	s := resourceSample{Cycle: cycle, Seconds: elapsed.Seconds()}
	tree, err := processTree(ctx, pid)
	if err != nil {
		return s, err
	}
	found := false
	for _, p := range tree {
		if p.PID == pid {
			s.RSSKiB = p.RSSKiB
			found = true
		} else {
			s.Descendants++
			s.NativeRSSKiB += p.RSSKiB
		}
	}
	if !found {
		return s, errors.New("sampled daemon disappeared")
	}
	out, err := exec.CommandContext(ctx, "/usr/sbin/lsof", "-nP", "-a", "-p", strconv.Itoa(pid), "-Ff").Output()
	if err != nil {
		return s, err
	}
	for _, line := range strings.Split(string(out), "\n") {
		if len(line) > 1 && line[0] == 'f' && line[1] >= '0' && line[1] <= '9' {
			s.FDs++
		}
	}
	if s.FDs == 0 {
		return s, errors.New("no file descriptor evidence")
	}
	return s, nil
}

func waitEmptyProcessTree(ctx context.Context, pid int) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	for {
		tree, err := processTree(ctx, pid)
		if err != nil {
			return err
		}
		if len(tree) == 1 && tree[0].PID == pid {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("empty history retained process tree: %+v", tree)
		case <-time.After(50 * time.Millisecond):
		}
	}
}

// Observe natural exit before fallback cleanup. A survivor always fails the gate.
func sameProcess(want, actual processSample) bool {
	return want.PID == actual.PID && want.Started != "" && want.Started == actual.Started && want.PGID == actual.PGID && (want.Command == "" || want.Command == actual.Command)
}
func liveOwned(ctx context.Context, wanted []processSample) ([]processSample, error) {
	rows, e := systemProcesses(ctx)
	if e != nil {
		return nil, e
	}
	byID := map[int]processSample{}
	for _, r := range rows {
		byID[r.PID] = r
	}
	live := map[int]processSample{}
	for _, p := range wanted {
		actual, exists := byID[p.PID]
		if exists && !sameProcess(p, actual) {
			continue
		} // A reused PID is never owned.
		if exists {
			live[p.PID] = actual
		}
		// A recorded native leader owns its process group even if it exited and
		// descendants were reparented. Do not infer groups from non-leader records.
		if p.PID == p.PGID && p.Started != "" {
			for _, r := range rows {
				if r.PGID == p.PGID {
					live[r.PID] = r
				}
			}
		}
	}
	result := []processSample{}
	for _, p := range live {
		result = append(result, p)
	}
	return result, nil
}
func registeredNative(root string) ([]processSample, error) {
	b, e := os.ReadFile(filepath.Join(root, "native-owned.tsv"))
	if e != nil {
		return nil, e
	}
	var rows []processSample
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Fields(line)
		if len(f) == 0 {
			continue
		}
		if len(f) != 7 {
			return nil, fmt.Errorf("invalid native registration: %q", line)
		}
		pid, e := strconv.Atoi(f[0])
		if e != nil {
			return nil, e
		}
		pgid, e := strconv.Atoi(f[1])
		if e != nil {
			return nil, e
		}
		rows = append(rows, processSample{PID: pid, PGID: pgid, Started: strings.Join(f[2:], " ")})
	}
	return rows, nil
}
func waitProcessesGone(ctx context.Context, ps []processSample) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	for {
		live, e := liveOwned(ctx, ps)
		if e != nil {
			return e
		}
		if len(live) == 0 {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("owned processes survived: %+v", live)
		case <-time.After(50 * time.Millisecond):
		}
	}
}
func cleanupProcesses(ps []processSample) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	live, e := liveOwned(ctx, ps)
	if e != nil {
		return
	} // Unverifiable identity is not permission to kill.
	for _, p := range live {
		current, e := liveOwned(ctx, []processSample{p})
		if e != nil {
			continue
		}
		for _, q := range current {
			if sameProcess(p, q) {
				_ = syscall.Kill(q.PID, syscall.SIGKILL)
			}
		}
	}
}
func median(values []int) int { v := append([]int{}, values...); slices.Sort(v); return v[len(v)/2] }
func verifyResources(samples []resourceSample) error {
	// The first five cycles are warmup. Compare equal, empty-history states.
	if len(samples) < 15 {
		return errors.New("resource gate needs 15 samples including five warmup cycles")
	}
	base, last := samples[5:10], samples[len(samples)-5:]
	values := func(s []resourceSample, rss bool) []int {
		out := []int{}
		for _, v := range s {
			if rss {
				out = append(out, v.RSSKiB)
			} else {
				out = append(out, v.FDs)
			}
		}
		return out
	}
	bRSS, eRSS := median(values(base, true)), median(values(last, true))
	bFD, eFD := median(values(base, false)), median(values(last, false))
	if eRSS > bRSS+max(64*1024, bRSS/2) {
		return fmt.Errorf("RSS gate failed: baseline=%d KiB final=%d KiB", bRSS, eRSS)
	}
	if eFD > bFD+8 {
		return fmt.Errorf("FD gate failed: baseline=%d final=%d", bFD, eFD)
	}
	// Also bound transient high water after warmup; endpoint medians alone can
	// conceal a resource spike or later recovery from a large leak.
	for _, s := range samples[10:] {
		if s.FDs > bFD+8 || s.RSSKiB > bRSS+max(64*1024, bRSS/2) || s.Descendants != 0 {
			return fmt.Errorf("resource high-water gate failed at cycle %d: %+v baselineRSS=%d baselineFD=%d", s.Cycle, s, bRSS, bFD)
		}
	}
	return nil
}

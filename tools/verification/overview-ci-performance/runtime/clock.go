//go:build cgo && (darwin || linux)

package main

/*
#include <errno.h>
#include <stdint.h>
#include <time.h>

#if defined(__APPLE__)
#define OVERVIEW_RAW_CLOCK CLOCK_UPTIME_RAW
#elif defined(__linux__)
#define OVERVIEW_RAW_CLOCK CLOCK_MONOTONIC_RAW
#endif

// The OS clock has the same epoch in both processes. No private Go runtime
// symbol, realtime offset, or long-lived Go-to-raw conversion is involved.
static int overview_raw_clock(int64_t *value) {
    struct timespec sample;
    if (clock_gettime(OVERVIEW_RAW_CLOCK, &sample) != 0) return errno;
    *value = (int64_t)sample.tv_sec * 1000000000LL + sample.tv_nsec;
    return 0;
}

static int overview_clock_observation(int64_t *before, int64_t *realtime, int64_t *after) {
    int error = overview_raw_clock(before);
    if (error != 0) return error;
    struct timespec sample;
    if (clock_gettime(CLOCK_REALTIME, &sample) != 0) return errno;
    *realtime = (int64_t)sample.tv_sec * 1000000000LL + sample.tv_nsec;
    return overview_raw_clock(after);
}
*/
import "C"

import (
	"context"
	"fmt"
	"runtime"
	"syscall"
	"time"
)

const measurementClockVersion = 2

func measurementClockID() string {
	if runtime.GOOS == "darwin" {
		return "darwin.CLOCK_UPTIME_RAW.ns"
	}
	return "linux.CLOCK_MONOTONIC_RAW.ns"
}

type clockObservation struct {
	UptimeNanoseconds      int64 `json:"uptimeNanoseconds"`
	UnixNanoseconds        int64 `json:"unixNanoseconds"`
	UncertaintyNanoseconds int64 `json:"uncertaintyNanoseconds"`
}

type clockEnvelope struct {
	MeasurementClockVersion      int              `json:"measurementClockVersion"`
	MeasurementClockID           string           `json:"measurementClockID"`
	ClockOriginUptimeNanoseconds int64            `json:"clockOriginUptimeNanoseconds"`
	ClockObservation             clockObservation `json:"clockObservation"`
}

func (b *benchmark) observeEnvelope() (clockEnvelope, error) {
	observation, err := observeClock()
	return clockEnvelope{MeasurementClockVersion: measurementClockVersion, MeasurementClockID: measurementClockID(),
		ClockOriginUptimeNanoseconds: b.origin.UptimeNanoseconds, ClockObservation: observation}, err
}

func rawUptimeNanoseconds() (int64, error) {
	var value C.int64_t
	if code := C.overview_raw_clock(&value); code != 0 {
		return 0, fmt.Errorf("read %s: %w", measurementClockID(), syscall.Errno(code))
	}
	if value <= 0 {
		return 0, fmt.Errorf("read %s: nonpositive uptime", measurementClockID())
	}
	return int64(value), nil
}

func observeClock() (clockObservation, error) {
	var before, realtime, after C.int64_t
	if code := C.overview_clock_observation(&before, &realtime, &after); code != 0 {
		return clockObservation{}, fmt.Errorf("observe %s: %w", measurementClockID(), syscall.Errno(code))
	}
	if before <= 0 || after < before {
		return clockObservation{}, fmt.Errorf("observe %s: invalid raw bracket", measurementClockID())
	}
	return clockObservation{UptimeNanoseconds: int64(before + (after-before)/2),
		UnixNanoseconds: int64(realtime), UncertaintyNanoseconds: int64((after - before + 1) / 2)}, nil
}

// UTC is a human-readable diagnostic estimate only. No deadline, phase, CPU
// duration or delivery latency is computed from this conversion.
func (origin clockObservation) diagnosticUnix(uptime int64) int64 {
	return origin.UnixNanoseconds + uptime - origin.UptimeNanoseconds
}

func (b *benchmark) attachClock(value map[string]any) error {
	envelope, err := b.observeEnvelope()
	value["measurementClockVersion"] = measurementClockVersion
	value["measurementClockID"] = measurementClockID()
	value["clockOriginUptimeNanoseconds"] = b.origin.UptimeNanoseconds
	value["clockObservation"] = envelope.ClockObservation
	return err
}

// Go timers provide a relative wakeup only. Every remaining duration and every
// wakeup decision is recomputed in the OS raw clock, including on Linux where
// Go's timer clock need not have the same frequency as CLOCK_MONOTONIC_RAW.
func waitUntilRaw(ctx context.Context, deadline int64) error {
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		now, err := rawUptimeNanoseconds()
		if err != nil {
			return err
		}
		if now >= deadline {
			return nil
		}
		timer := time.NewTimer(time.Duration(deadline - now))
		select {
		case <-timer.C:
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		}
	}
}

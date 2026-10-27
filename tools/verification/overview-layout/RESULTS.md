# Local result — 2026-10-26

Baseline: `3ad8be6c1ea113b214bdf27b3ba3c7b8c0693b3c`. Current worktree production source, optimized standalone Swift geometry, three repetitions. Actual toolbar clearance: 60pt wide / 120pt narrow. Raw source, full samples and executables: `/private/tmp/overview-layout-final`. Compact reproducible metrics are committed alongside this report.

| Scenario | Visible fill before → after | Max survivor screen shift | Search steps | Median solver ms before → after |
| --- | --- | --- | --- | --- |
| three-600 | 57.10% → 57.10% | 0.00 → 0.00pt | 57 → 57 | 0.7956 → 0.7611 |
| three-900 | 39.37% → 49.79% | 0.00 → 0.00pt | 57 → 66 | 0.0205 → 0.0264 |
| three-1420 | 23.48% → 23.48% | 0.00 → 0.00pt | 57 → 57 | 0.0148 → 0.0144 |
| three-1920 | 16.62% → 16.62% | 0.00 → 0.00pt | 57 → 57 | 0.0133 → 0.0154 |
| three-2560 | 16.62% → 16.62% | 0.00 → 0.00pt | 57 → 57 | 0.0129 → 0.0154 |
| six | 46.96% → 46.96% | 0.00 → 0.00pt | 143 → 143 | 0.0216 → 0.0255 |
| six-repeat | 46.96% → 46.96% | 0.00 → 0.00pt | 143 → 0 | 0.0472 → 0.0182 |
| six-reversed | 46.96% → 46.96% | 0.00 → 0.00pt | 143 → 0 | 0.0327 → 0.0069 |
| six-to-seven | 54.79% → 54.79% | 188.00 → 98.00pt | 750 → 9 | 0.1355 → 0.0135 |
| delete-center | 62.62% → 62.62% | 376.00 → 0.00pt | 20188 → 0 | 1.5867 → 0.0100 |
| refill-center | 70.44% → 70.44% | 0.00 → 0.00pt | 669 → 5 | 0.0941 → 0.0083 |
| fresh-16 | 66.98% → 66.98% | 0.00 → 0.00pt | 544 → 544 | 0.0494 → 0.0528 |
| fresh-30 | 89.31% → 89.31% | 0.00 → 0.00pt | 1411 → 1411 | 0.0922 → 0.0937 |
| fresh-100 | 87.50% → 87.50% | 0.00 → 0.00pt | 9019 → 9019 | 0.4445 → 0.4489 |
| fresh-500 | 90.30% → 90.30% | 0.00 → 0.00pt | 104785 → 104785 | 4.2467 → 4.2372 |

The deletion keeps 8/9 grid occupancy; survivor total screen travel falls from 592pt to zero. Six-to-seven keeps seven complete visible cards: total travel falls from 1128pt to 588pt. A 98pt shift is necessary to fit the new right edge at the existing scale; this implementation deliberately preserves complete visibility rather than promising zero motion when it cannot fit. Same/reversed geometry still validates inputs in the standalone solver; the native Canvas bypasses even that call.

Timings were collected alongside other local checks, with only three samples. They are diagnostic medians, not controlled performance claims or p95 estimates. No GPU, optical frame time, content truncation or VoiceOver speech/focus measurements are inferred from these results.

Validation on the final code:

- `make check ARGS=` passed (architecture, formatting, Go vet/build, Swift build, concurrency properties, module tests and directory tags). The shell exported `ARGS=-fresh`; clearing it avoids passing an unrelated flag to Go tests.
- `MOKUSEI_OVERVIEW_SEARCH_NATIVE_REPLAY=1 xcrun swift test --package-path app/macos --no-parallel --filter 'NativeOverview|SwiftUIOverviewInteraction'` reported 129 tests in 18 suites passed, in 128.661s. Six environment-gated producer/tag-glass tests were skipped. Capacity, packing, resize, transitions, membership, search, camera, mounting, input/focus and the new regressions ran.
- `python3 tools/verification/overview-input/run.py` passed: `PASS Overview SwiftUI replay completed`. Isolated app: `/private/tmp/mokusei-overview-px5ofgmb/OverviewInputReplay.app`; no user Runtime/profile was launched.
- The standalone three-repeat comparison and its regression assertions passed. `git diff --check` passed; local review covered cancellation/ownership, same-footprint revision acknowledgement, filter/bookmark restoration, readable capacity, collision fallback, manual framing and reduced-motion stage ownership.

Local full logs: `/private/tmp/overview-check-final.log`, `/private/tmp/overview-native-verified.log`, `/private/tmp/overview-input-final.log`, `/private/tmp/overview-layout-final.log`.

The first native pass exposed filter-policy scope that was too broad; explicit filters now retain the historical compact planner. One existing transition fixture assumed initial six cards were always 2×3. Its setup now accepts either 2×3 or 3×2 while retaining all compact-filter and visible-survivor assertions. The final full rerun passed.

Limits: conflicting footprint growth still invokes global collision planning and can repack; editor-specific hard locks, resize hysteresis, pending-work coalescing and virtualization are deferred. Native capacity tests measure actual SwiftUI frames and motion policy, including reduced motion, but do not audit VoiceOver speech/focus or optical frame pacing/GPU. Narrow 600pt and very large windows are covered by production geometry comparisons; native capacity windows cover the existing 860–1500pt range. No new WindowServer recording or manual accessibility audit is claimed.

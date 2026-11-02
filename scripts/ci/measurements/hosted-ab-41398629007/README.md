# Hosted native-observer diagnostic (2026-11-02)

[Run 41398629007, attempt 1](https://github.com/hupao-creator/Mokusei/actions/runs/41398629007)
failed. This was a dispatch-only diagnostic on `579dbc22`, not a PR or a
`Complete coverage` run. One hosted Mac built the `d3430ad` product once and
ran the same seven native methods in A/B/B/A order. A used the `916fd32`
zero-tolerance sleep observer; B used the `3c5e9e7` main-queue observer. Both
kept the same latency-critical app, current build, original assertions and
input sequence. The product revision predates main `fe4af9a`; this experiment
cannot certify the newer product or classify an earlier failure as harmless.

| Original native method | 1-A | 2-B | 3-B | 4-A |
| --- | --- | --- | --- | --- |
| Tag production first-frame capture | pass | pass | pass | fail: one frame |
| Native cloud/scan composition | pass | pass | pass | pass |
| Directory selection and glass resize | pass | pass | pass | pass |
| Short-child capsule morph | pass | pass | pass | pass |
| Retained Overview return | pass | fail: missed midpoint | fail: missed midpoint | pass |
| Title reversal and cancellation | fail: incoming frame | pass | fail: incoming frame | pass |
| Excerpt rewrite and width motion | pass | pass | pass | pass |

Every command exited 1. Their elapsed times were 112.286, 71.065, 76.193 and
72.945 seconds respectively, including launcher staging/compilation. The job
queued for 3 seconds, executed for 12 minutes 5 seconds, and the run lasted
12 minutes 10 seconds from first trigger. There was no retry.

In 2-B the opening samples crossed from x=734 to 294 in 65.87 ms; in 3-B they
crossed from x=780 to 382 in 75.91 ms. Neither observed the unchanged 472–708
midpoint band. B's largest timer schedule-to-fire delays were 99.92 and 96.87 ms;
largest fire-to-actor-resumption delays were 3.25 and 7.19 ms. The two A runs
did observe an actual midpoint, despite maximum polling gaps of 90.53 and
72.36 ms. These few samples do not establish a general distribution, but they
do not support the main-queue timer as a reliable fix.

For 1-A, the analyzed incoming frame had 14,196 / 141,325 ink (10.05%) but
was 57.07 ms old, outside the unchanged 50 ms freshness bound; the next
analyzed live frame had 108,609 ink (76.85%), outside the 10–60% band. In 3-B,
the corresponding live samples had 3,605 (2.55%) and 87,512 (61.92%) ink.
The 4-A Tag entry retained only one complete frame during its existing capture
window. These are incomplete observations, not evidence that the product was
correct or incorrect. No deadline, frame-age, pixel, midpoint or count assertion
was relaxed, and no frame or failed condition was removed.

The [comparison](comparison.json) preserves exact input hashes, order and
process receipts. The four raw replay logs and representative failure frames
are retained beside this report. The complete original artifact, including all
frames and build evidence, is preserved locally at
`/private/tmp/mokusei-ci-observer-ab-41398629007` and in the run's
`observer-ab-attempt-1` artifact (GitHub retention: seven days).

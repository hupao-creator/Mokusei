# Historical native CI review, 2026-11-02

The user's independent read-only investigation supplied candidate failures.
This review checked their original job logs, actual merge checkouts, retry jobs,
retained artifacts and the current implementation before changing selection.
Same-commit retry success alone does not classify an original failure as harmless.

## Directory-selection glass candidate

`NativeOverviewTagGlassTests.directorySelectionResizeKeepsRoundedGlass()` failed
at the historical `NativeOverviewTagGlassTests.swift:342:17` predicate
`top.count == 4 && middle.count == 4`, on `shrinking-5`, in both first attempts:

| Run | Actual checkout (from original checkout log) | Failed native job | Native job interval (UTC) | Retry native job |
| --- | --- | --- | --- | --- |
| [40662756641 attempt 1](https://github.com/hupao-creator/Mokusei/actions/runs/40662756641/attempts/1) | `a0cf852547ccef5c24601efd219c71b6de3d0a50` | [122731511928](https://github.com/hupao-creator/Mokusei/actions/runs/40662756641/job/122731511928) | 09:19:27–09:23:15, 2026-10-28 | [122735032260](https://github.com/hupao-creator/Mokusei/actions/runs/40662756641/job/122735032260), success, same checkout |
| [40665426686 attempt 1](https://github.com/hupao-creator/Mokusei/actions/runs/40665426686/attempts/1) | `f5fcdb6c1f8d8803f373d2730f54415892093983` | [122741109319](https://github.com/hupao-creator/Mokusei/actions/runs/40665426686/job/122741109319) | 09:41:16–09:45:12, 2026-10-28 | [122745517831](https://github.com/hupao-creator/Mokusei/actions/runs/40665426686/job/122745517831), success, same checkout |

The original test processes exited 1 with a named assertion; these were not queue
failures or command timeouts. The individual glass cases took 3.021s and 2.956s.
The API's `head_sha` identifies the PR branch head, not the tested merge checkout;
use the checkout log and replay report for actual source identity.

The currently downloadable `macos-swift-3-evidence` artifacts, IDs 12805581170
and 12806064495, contain **passing retry** replay reports and screenshots. They
do not preserve the failed `shrinking-5` frame. Their passing frame cannot be
used as the failed frame or to certify the original failure as a false alarm.
The first-attempt logs establish only that the top count was four and the middle
count was not four; they do not give the actual middle count.

Current main already includes [063eb777bb79817b8840b3af6c16cf94670ed043,
“Repair main native CI failures against the real contracts”](https://github.com/hupao-creator/Mokusei/commit/063eb777bb79817b8840b3af6c16cf94670ed043).
That change explicitly accounts for GlassEffectContainer blending adjacent
capsules during a morph. In the current implementation, moving captures may
have four top caps and fewer middle spans; settled captures still need four
separate spans, and separated capsules retain the rounded-end inset checks.
The shrink/expand calls explicitly select the moving-capture contract. Other
counts still fail. Thus the historical strict-four-span predicate is no longer
the current moving-frame predicate. The missing original pixels prevent a more
specific comparison against the corrected predicate.

Decision: retain the current case on this evidence. The supplied failures predate
its relevant correction; they do not demonstrate a remaining current-version
flake. Precise retirement remains a possible explicit coverage tradeoff, not a
claim that its existing assertion failure was harmless. Retiring this method
would remove the independent child→other-tag→child resize, intermediate capsule
rounding and leading/trailing scroll-edge clipping pixel coverage. The distinct
`shortChildMorphKeepsBothCapsuleEnds`, prefix geometry, selection/menu/input,
long-title/zoom and directory-width tests would remain, but are not equivalent
to every assertion in this method.

## Other candidates

- `NativeOverviewTransitionTests.aNewRevisionDoesNotInterruptAnEntryAlreadyInFlight()`:
  the supplied [41167622461](https://github.com/hupao-creator/Mokusei/actions/runs/41167622461)
  retry alone does not establish a current flake. Current code and the
  [test-support timing contract](../../app/macos/Tests/Support/README.md#overview-revision-timing)
  observe real descending geometry before injection and wait for actual final
  mounted membership. The later correction is present in `fe4af9a` (“Remove
  Overview carousel navigation”). Retain the case and its state/FIFO assertions.
- `RollingNumberCellTests.incomingDigitsMoveDownFromAbove()` is already deleted
  from current sources under earlier explicit authorization; do not repeat the
  removal or claim new coverage. The [Swift audit](../../tools/verification/swift-tests/README.md)
  records that history.
- Title reversal/cancellation has production animation and optical evidence
  obligations and subsequent observer fixes. No evidence supplied here isolates
  a remaining harmless flake; retain its mandatory native owner and assertions.
- Moku execution-link and history-composer failures lack sufficient evidence for
  removal. Retain these production interaction boundaries.

No test, assertion, frame, deadline or native owner is removed or weakened by
this review. No retry was triggered and no old run certifies the migration commit.
Downloaded logs/artifacts remain in `/tmp/mokusei-glass-*` on the inspection host;
no credentials or binary evidence are committed to the repository.

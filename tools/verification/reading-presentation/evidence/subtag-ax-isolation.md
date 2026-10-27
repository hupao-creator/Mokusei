# Child AX disappearance: state and hover isolation

Follow-up to independent review of `a451b80f94ea454c7d5d684c5d601de6f90932ab`.
Production remains the two 320→220ms opening changes on
`e70ca9877603d978d9910d73a4a1b32a614837dc`, including directory-capsule clipping
and Glass world. This follow-up changes only the native verification fixture.

## Controlled reproduction and classification

The failing test opens a production menu through AX, observes it for 300ms,
drives direct scroll snapshots, then selects a child through AX. Its original
window was visible on the desktop. Placing it opposite the pointer at creation
did not prevent subsequent physical hover during this observation.

A controlled experiment moved only the replay's window beneath the stationary
pointer for 80ms and returned it to its previous position. It did not move the
pointer or inject a hover callback. Temporary instrumentation recorded actual
production scope transitions and hover-clear scheduling. The same child AX
lookup failed on both duration variants:

| Production opening | Open scope time (uptime s) | Hover close scheduled | Scope becomes nil | State at failed child lookup |
| --- | --- | --- | --- | --- |
| e70ca987 baseline: 320ms | 651721.339046 | 651721.456951 | 651721.645150 | scope nil, menu still mounted for exit, AX child absent |
| a451b80f speed: 220ms | 651666.379714 | 651666.499931 | 651666.693676 | scope nil, menu still mounted for exit, AX child absent |

The 188.20/193.74ms schedule-to-close intervals match the unchanged 180ms hover
clear plus event-loop scheduling. This is a real, intended production close:
`active` becomes false, so retiring controls are hidden from AX immediately,
while their glass remains mounted for the 320ms return. It is not an AX tree
that lost a still-active child, nor a stale spring completion overwriting scope.
The shorter opening duration is not required for this failure mechanism.

The original independent-review runs did not record scope or hover events;
we cannot reconstruct their exact pointer timeline retrospectively. The controlled
experiment reproduces their same child and same pre-selection lookup failure,
and demonstrates the concrete hole in the verifier's physical-pointer isolation.

Additional bounded comparisons, retained locally, ran three normal targeted
cases per duration before choosing a fix; all passed. An AX object-lifetime
hypothesis was investigated with weak references: no visited proxy deallocation
or address reuse was observed, so the AX traversal was left unchanged.
`ignoresMouseEvents` did not prevent SwiftUI hover tracking in the controlled
experiment and was rejected. Merely requesting an offscreen origin also failed
its geometry assertion because AppKit constrained the window onto a screen.

## Fix

Only this AX/direct-scroll case requests an offscreen native replay window.
The test host disables AppKit's frame constraint for that explicit option and
positions the window above all attached screens **before ordering it front**.
It still hosts the production Chrome and Canvas in the AppKit event loop.
Default replay windows retain ordinary frame constraints and visible placement.

Assertions require the window to remain outside every screen. Immediately before
child selection, separate assertions require the production interaction registry
to report the expected open scope and mounted menu. Future state loss therefore
fails at its actual boundary rather than being reported only as a missing AX
node. The AX search, production selection, exit/reopen logic, scroll snapshots,
300ms observation and all timeouts remain unchanged. No retry or fallback lookup
was added. Production hover behavior and input handling remain unchanged.

The pointer-isolated 320ms baseline passed the same native case (5.553s), with
both wide/narrow menus active at all pre-selection state samples. Final 220ms
validation is listed below. The actual glass pixel cases continue to use
onscreen WindowServer captures; the isolated AX/direct-scroll case makes no
claim about physical pointer/trackpad delivery or onscreen frame pacing.

## Reproduction and retained evidence

The inert [220ms diagnostic patch](subtag-ax-isolation/diagnostic.patch) applies
to a451b80f in a separate isolated checkout. The
[320ms patch](subtag-ax-isolation/baseline-diagnostic.patch) applies to e70ca987.
They contain temporary production logging and the controlled window movement;
neither is applied to the final source. Run the patched production tag suite:

```sh
MOKUSEI_TAG_HOVER_CHALLENGE=1 python3 tools/verification/reading-presentation/run.py --tag-glass
```

The negative control is expected to fail at the child lookup with scope nil.
It uses native window movement, so reproduce on a normal unlocked macOS desktop.
No global pointer event, runtime, model, deployment or push is involved.
The original review evidence is read-only at
`/Users/example/OpenAgent/.build/verification/subtag-independent-a451b80f/review.json`.
Full diagnostic/matrix logs and timing controls are retained in this worktree's
`.build/verification/subtag-ax-root-cause/`; the original screenshot evidence is
[unchanged](subtag-transition-speed.md).

## Final validation

- All seven production native tag-glass cases passed (33.603s), including
  directory shape/clipping pixels and the corrected AX/direct-scroll case.
- Three predetermined serial executions of that same final binary's formerly
  failing case passed: 5.572s, 5.615s, 5.704s. Offscreen placement, open scope and
  mounted-menu invariants were required; the original AX traversal was used.
- `env -u MAKEFLAGS -u MAKEOVERRIDES -u MFLAGS make check ARGS=` passed, including
  architecture/format, Go vet/build, Swift test build, concurrency properties,
  module tests and 13 native directory-tag cases.
- Local diff/link review passed. Both diagnostic patches were checked against
  fresh copies of their declared source revisions. No diagnostic logging remains
  in production or in the shipped replay code.
- Six Glass world mounting replays were not rerun: production is unchanged from
  the previously reviewed e70ca987 plus the two opening-duration substitutions.
  No performance benchmark or physical trackpad-delivery test was run.

[Machine-readable results](subtag-ax-isolation/results.json).

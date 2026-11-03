# Note opening performance and Regular glass

This investigation starts at `61e424b` and uses the user-supplied 10.29-second
screen recording from 2026-11-03. Frames were decoded with AVFoundation at exact
100 ms requests (default keyframe tolerance is unsuitable for animation review).
The recording contains two openings of a short note with one execution link;
it supports investigating opening/morph work, rather than assuming a long
note or a slow remote read. Private recording frames and note text are not
checked in.

## Production path and cause

- `NativeMokuWorkspacePresentation` projects the note from the public catalog.
  Opening toggles `NativeMokuSceneState.notePanelOpen`; it does not fetch a
  transcript, read a note file, start a Harness or invoke a backend load.
- `NativeMokuDock` fits the measured body into the viewport and animates its
  existing shell. The read-only Markdown parser runs on its background actor;
  native attributed text and TextKit layout run on the main actor.
- The Note opts into execution capsules even in ordinary prose paragraphs.
  Previously, every changed sizing proposal rebuilt their attributed text.
  Execution attachments were new native objects, invalidating text storage,
  selection notifications, height caches and native layout even for a return
  to an already measured width.
- `updateExecutionSurfaces` assigned each capsule's frame and SwiftUI root on
  every layout/selection refresh. A new root invalidated another live glass
  graph despite unchanged content. A two-second sample of the isolated baseline
  reached `sizeThatFits → measuredHeight → applyText → replaceContent →
  NSTextStorage → selection notification → updateExecutionSurfaces`, alongside
  AttributeGraph layout, `NSHostingView.rootView.setter` and `GlassEffectView`
  updates. This is evidence of repeated CPU/render preparation feeding glass,
  not a measurement of GPU time.
- The outer Note shell shares the Dock window; execution capsules are child
  hosting views inside TextKit, not additional windows. The Note ink's existing
  compositing group owns its fade; it is not another outer glass shell.
  Exposure probes inspect layout and coverage but do not load data. Their
  qualification, dwell, cancellation and backend receipt behavior are unchanged.

The fix keeps eight width/scale heights per text input revision and checks them
before building attributed content. A proposal always restores the actual
visible container. Only actual image/execution attachments make content
width-dependent. Glass roots update only for attachment, selection, locale or
appearance changes, while actions still read the latest callback.

Expanded Note now uses **dark Regular Liquid Glass**, as requested, without the
clear shell's bottom-fading gradient. A single persistent `glassEffect` node
changes material; there is no second clear shell behind Regular. Collapsing
restores the existing clear interactive Dock. Expanded Regular is noninteractive;
TextKit, scroll, close/history buttons and input retain event ownership. Reduce
Transparency takes the original opaque warm-black branch for either state.
The existing 420 ms shell and 120 ms ink-dismissal timing, including Reduce
Motion, remain with their existing owners.

## Reproduce the measurement

The probe links optimized production objects and mounts the real Note content
and Dock in a **never-ordered, never-activated window**. It uses synthetic notes,
no Runtime/profile, account, network operation, global preference or clipboard.
No test suite or historical replay is invoked. `-enable-testing` only exposes
internal production types to the standalone executable.

Before changing production sources, preserve a baseline, then preserve the
candidate after the change:

```sh
python3 tools/verification/moku-note-performance/run.py build --label baseline
python3 tools/verification/moku-note-performance/run.py build --label candidate
python3 tools/verification/moku-note-performance/run.py measure \
  --labels baseline,candidate --repetitions 4
```

Run serially in the same checkout and graphical session, without concurrent
builds/profilers. The detached HEAD is never changed. The driver retains source
fingerprints, the probe source, binaries, compiler command and raw runs under
`.build/moku-note-performance`. It alternates AB/BA and rejects mismatched probe
sources, changed binaries, missing controls and visible/active probe windows.
`--skip-build` only links production objects that the caller has just built from
current sources. Build/link and measurement failures keep their evidence.

For separate production counters (excluded from timing), run a preserved binary
with `OUTPUT.json --detail`. A system `sample` of that owned process can explain
CPU stacks; sampling runs must not be included in the timing comparison.

`unchanged-execution-layout` performs 30 identical native refreshes per case;
`alternate-width-proposals` performs ten actual/actual+16/actual sizing cycles.
Cases contain zero, one and twelve execution links. Each process also opens and
closes the production Dock four times. Its 650 ms observation interval includes
async work, native layout, character animation and hidden-window rendering;
it is not time-to-visible. `glassViews` in raw data counts native class names
containing "Glass"; SwiftUI's glass graph need not expose such an NSView, so
zero does not mean glass was absent.

## Evidence and limits

Measured on arm64 macOS 26.5.1 with Swift 6.3.2, optimized production objects,
four serial AB/BA pairs after all builds completed. Each number is the median of
four process medians; bracketed values are their range, in milliseconds.
The final column includes both the layout fix and expanded Regular material.

| Production boundary | Original clear Note | Final Regular Note |
| --- | ---: | ---: |
| Unchanged refresh, 1 link | 0.390 [0.358–0.410] | 0.018 [0.006–0.041] |
| Width probes, 1 link | 3.299 [3.149–3.834] | 0.009 [0.009–0.009] |
| Unchanged refresh, 12 links | 4.896 [4.697–5.166] | 0.164 [0.160–0.327] |
| Width probes, 12 links | 39.109 [37.914–41.886] | 0.182 [0.179–0.194] |
| Width probes, ordinary prose | 0.023 [0.022–0.070] | 0.0034 [0.0033–0.0068] |
| Warm Dock opening, process CPU in ~650 ms observation | 682.6 [666.6–692.5] | 663.5 [660.5–670.7] |

The repeated work is substantially cheaper; the whole hidden-window observation
only improves modestly and its ranges overlap. It includes unrelated character
and native/software drawing work. **These results do not establish the real
application's opening latency, GPU performance or smooth frame rate.** The
cache-only intermediate build also reduced the single-link width cycle to
0.0088 ms (from 3.398 ms in its own four-pair series), separating the CPU fix
from the subsequent material change. Do not pool those series.

[Raw final-pair records](evidence/measurements.jsonl) retain every timed sample,
mount counts, observation flags, wall/CPU intervals and geometry.
[Provenance](evidence/provenance.json) records source/probe/binary identities.
The original baseline was compiled from clean `61e424b` before editing production
sources; its preserved executable was linked with the identical probe source.
Raw local binaries, build logs, sampled stacks and preliminary runs remain under
`.build/moku-note-performance` and `/tmp/moku-note-performance` in this worktree.

Separate [production diagnostic counts](evidence/diagnostic-counts.json) created
43 text views in each baseline/final process. Attributed constructions went from
2,373 to 124, storage replacements from 2,274 to 124, and layouts from 2,332 to
153. The baseline counter run was exploratory (overlapping another probe), so
its durations are not timing evidence; counts describe that fixture observation.
The ordinary parser performed three parses, ~8 ms total, in both cases. No
network/data-load explanation was needed for this isolated reproduction.

### Actual visual and interaction observations

Plain `cacheDisplay` snapshots omitted the native glass sampling layer and were
rejected as readability evidence. Subsequent ScreenCaptureKit captures included
only the diagnostic process's own WindowServer window. That window was ordered
behind existing windows, never activated, ignored mouse input, and closed after
each capture. [Capture observations](evidence/capture.txt) show that the foreground
application remained unchanged in all three cases. User notes/profiles, global
preferences and the clipboard were never modified.

- [Light background](evidence/light.png): actual production Dock/Note with dark
  Regular glass; body, date, link and history remain visibly separated from the
  bright background.
- [Detailed colored background](evidence/complex.png): actual production Dock;
  Regular blurs and darkens the background detail beneath the white text.
- [Opaque branch](evidence/complex-opaque.png): production Note content and the
  existing material's `forceOpaque` preview entry. Text remains legible over the
  same detailed fixture. This exercises the shared opaque branch, **not a live
  change to the system Reduce Transparency preference**.
- Open/close in the real Dock retained the synthetic draft and returned the shell
  from 560×253.5 to 168×44 points. Four repeated opens per measured process also
  mounted the same expected controls. Timings and animation ownership were
  source-reviewed; captures are settled frames, not a smoothness certification.
- [Offscreen interaction observations](evidence/interaction.json): repeated width
  probes retained the native host and selection, restored the actual 300-point
  container, preserved full-title plain-copy text, reflowed at 140 points, routed
  Enter on the selected link to the diagnostic delegate and removed native hosts
  after replacing the content. Copy was inspected without touching the clipboard.
  The inactive offscreen AX tree did not expose a pressable capsule, so AX press
  and callback refresh through that press remain **unverified**, not passed.

### Review and verification

Completed local diff review of input/cache ownership, bounded storage, callback
freshness, locale/appearance and attachment invalidation, event passthrough,
material identity, Reduce Transparency priority, and existing animation owners.
The final production source fingerprint is recorded in provenance; documentation
and evidence additions after its build do not change compiled sources.

- Release `Mokusei` product build with Swift 6 and `-warnings-as-errors`: passed.
- Architecture/static-registration/no-Node source checks: passed.
- Python syntax, diff whitespace and changed local documentation links: passed.
- No new tests, historical suites/replays, `make check`, git hooks, hosted CI,
  remote push or PR creation. Commit hooks are disabled for this scoped commit.
  Read-only remote inspection reported no legacy main branch-protection object;
  listed runs belonged to other commits and do not certify this work.

Diagnostic limitations/failures were retained: initial sandbox AVFoundation
hardware decoding failed and succeeded with read-only decoder access; a build
metadata guard rejected a concurrent README-only edit after successful compile
(the fingerprint now excludes Markdown docs); the runner refused to overwrite
an older measurement series (a unique series prefix now preserves both);
read-only accessibility environment overrides were replaced by the existing
local opaque preview entry. None was turned into a passing product test.

Not covered: live user-profile behavior, complete Harness navigation/focus/voice
regressions, full accessibility activation, live Reduce Motion/Transparency
preference changes, extreme zoom/mixed media, rapidly interrupted material
transitions, WindowServer frame pacing/GPU cost, or physical trackpad feel.
Those limits remain for caller integration; no user application was replaced or
restarted, and no note data was deleted.

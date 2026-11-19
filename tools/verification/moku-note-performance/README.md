# Note native preparation measurement

The probe links current optimized production objects, mounts the real Note/Dock
with synthetic data in a never-ordered, never-activated window, and measures
native layout/preparation. It uses no Runtime/profile, model, account, network,
clipboard or global preference writes. `-enable-testing` exposes internal types
without creating a test target. Hidden-window CPU is not visible opening latency.

The production Note comes from the public catalog, not a backend fetch when
opened. Its parser runs off main; attributed text/TextKit stay on main. Native
text uses bounded per-input width/scale height caching and updates execution-link
roots only for actual content/selection/locale/appearance changes. The expanded
shell is dark Regular Liquid Glass and uses opaque fallback under Reduce
Transparency. Ordinary shell/ink timing does not read Reduce Motion.

## Reproduce the measurement

The probe links optimized production objects and mounts the real Note content
and Dock in a **never-ordered, never-activated window**. It uses synthetic notes,
no Runtime/profile, account, network operation, global preference or clipboard.
No test suite or historical replay is invoked. `-enable-testing` only exposes
internal production types to the standalone executable.

Build two fixed compatible versions with the same probe source, preserving each
binary before measuring:

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

This independent probe writes CPU, geometry and timing outputs. A system
`sample` of its owned process can explain CPU stacks; sampling runs must not be
included in the timing comparison.

`unchanged-execution-layout` performs 30 identical native refreshes per case;
`alternate-width-proposals` performs ten actual/actual+16/actual sizing cycles.
Cases contain zero, one and twelve execution links. Each process also opens and
closes the production Dock four times. Its 650 ms observation interval includes
async work, native layout, character animation and hidden-window rendering;
it is not time-to-visible. `glassViews` in raw data counts native class names
containing "Glass"; SwiftUI's glass graph need not expose such an NSView, so
zero does not mean glass was absent.

## Versioned measurement evidence

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

# Prepare the reader during native panel travel

2026-11-04 · [work item #248](https://github.com/hupao-creator/Mokusei/issues/248)

After removing Overview bitmap capture, the remaining 0.8–1 second was mostly
serial presentation work. A fresh three-open baseline on the same real thread
created its reader at 612–694ms and delivered Markdown at 753–831ms. The existing
panel movement itself is deliberately 420ms; the reader's additional 135–142ms
was being paid after arrival. Data prefetch already overlaps opening and parsing
itself is normally much shorter than these wall-clock intervals.

## Implementation

- A generation-fenced native animation-start callback admits only the primary
  Agent reader. Its host remains transparent until panel completion. Input and
  accessibility remain closed and reading controls are unregistered while hidden.
- The reader keeps its identity through arrival; preparing data, decoding and
  creating native text can overlap compositor travel. Secondary surfaces and
  text entrance retain their existing actual-completion gates.
- Both title anchors must exist. Their publication is coalesced, native layout
  is resolved, and actual view geometry is frozen. A trailing 48ms debounce no
  longer restarts on each anchor update.
- Title handoff waits for actual panel completion and a visible host, replacing
  an independent duration timer. Early live anchors cannot prematurely retire
  the flying title. Close, replacement and cancellation fence late callbacks.
- Source-less and non-Agent entries retain their existing mounting gate. The
  shared window material and original 420ms travel curve remain unchanged.

The existing production fixture now requires real parsed TextKit content during
opening travel while the content still awaits its entrance. Its original 650ms
heading deadline is retained; no timing assertion was relaxed. No unit tests or
alternate reader implementation were added.

## Timings and limits

[Measurements and binary input hashes](thread-admission-performance.json) retain
three unsampled API-controlled opens per build, excluding startup restoration.
The final batch's process timestamps relative to opening were:

| Stage | Open 1 | Open 2 | Open 3 |
| --- | ---: | ---: | ---: |
| Both title anchors ready | 84ms | 164ms | 203ms |
| Animation installed | 96ms | 166ms | 205ms |
| Primary reader created | 123ms | 202ms | 230ms |
| Markdown delivered | 561ms | 542ms | 438ms |
| Panel completion callback | 527ms | 601ms | 633ms |

Median Markdown delivery decreased from 766ms to 542ms (about 29%). Two final
opens delivered Markdown before panel completion; one delivered 34ms afterward.
Text entrance still runs after admission, so neither Markdown delivery nor the
completion callback certifies a particular rendered pixel or full-text reveal.
The title image creation after resolved layout was about 2ms in these samples.

Initial native layout remains variable. An earlier probe with the same mounting
algorithm, before adding anchor/layout events, waited about 415ms before travel
on two opens and completed the panel around 873ms. Those observations are kept
in the JSON, not discarded as failures or advertised as a fixed upper bound.
The final batch does not prove that tail latency is eliminated. A sampled attempt
was used only to inspect stacks and is excluded from timing results. Desktop
load, OS/font caches and frame presentation were not controlled; this is not a
cold-start benchmark, FPS result or percentile guarantee.

Diagnostics use `reading.prepare`/`reading.transition` with `panel: 1` and
`closing: 0/1`. Anchor-ready, resolved-layout and native-start events separate
initial view admission from title rasterization and native travel. Raw data
remains local under `/private/tmp/moku-admission.AONkCb`; no thread body is stored
in the repository. Automation uses the application's own socket API exclusively.

## Validation and delivery scope

Final Debug build/signing/bundle verification and production panel replay passed.
The panel replay covers loaded and delayed content, title alignment (including
wide windows), hidden preloading, first-paint protection, text entrance, return
and interrupted opening. Reading navigation and retained Overview replays cover
cancellation, resize, history and return preparation: all 14 reading-navigation
checks and all 10 retained-Overview checks passed on the final production build.
The 154 final API observations exposed no reading controls during travel.

The user retained local-main-only integration, with no push. Remote PR and
`Complete coverage` rules were inspected and left intact. Hosted CI and an
equivalent full local `make check` are outside this requested delivery scope.

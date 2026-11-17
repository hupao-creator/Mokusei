# Super Thread cover viewport and native card geometry

## Cause and actual data path

The cover is generated HTML/CSS, not a generated image. Report Agent instructions
and the shared create/update `coverHTML` schema request a 360×308 viewport.
`ParseCoverHTML` admits passive markup without changing layout; `coverHTML` and
its independent `coverRevision` persist in the Report document. The catalog only
carries the revision. Mounted cards query `report.cover`, verify that revision,
and load the markup into a nonpersistent, input-transparent WKWebView with its
existing CSP. The plugin's 16-entry source/revision/appearance cache stores markup
and a final-frame image, not browsers. That image bridges browser admission and
remounts; it is not the authored cover format.

Commit `b06309ed` (Increase Overview card logical dimensions by 15 percent)
changed the base grid cell from 360×220 to 414×253pt, retaining the 16pt grid gap.
The Report 1×2 footprint consequently became 414×522pt. Its standalone and
collection covers still used a fixed 308pt height and received the entire new
414pt width as the WebKit viewport. Existing fixed-width documents stayed at
360px and aligned at the left; percentage layouts silently reflowed differently.
The production-backed demo still used 360×456pt, hiding the mismatch.

Two retained real-model HTML samples explicitly set `html, body` to 360×308px.
An isolated production-component baseline measured a 414×308 WebKit viewport and
360×308 body at x=0: 54pt of unused width on the right, with the composition
center 27pt left of the viewport center. At a 280pt panel width, the unchanged
360px body instead lost its rightmost 80px. The samples also contain deliberate
internal padding (e.g. 17px horizontally); that remains part of their composition.
This is a native viewport mismatch, independent of authored internal whitespace.

## Fix and dimensional contract

Keep 360×308 **CSS pixels** as the stable authoring canvas. `NativeReportCover`
now explicitly gives that size to both WebKit and the cached poster, then scales
the whole surface uniformly and centers it in the destination. Card and carousel
cover regions both use `width × 308/360`, so ordinary destinations fill exactly
without crop, letterboxing or stretched text. The carousel input and chrome use
the same derived height. The outer card footprint, 4pt spacing and metadata
styling stay as before; metadata receives the remaining height.

| Entry / card size (pt) | Cover size (pt) | Metadata height after 4pt gap |
| --- | --- | --- |
| Overview standalone / collection: 414×522 | 414×354.2 | 163.8 |
| Collection panel: 360×456 | 360×308 | 144 |
| Collection panel: 358×456 | 358×306.29 | 145.71 |
| Collection panel: 280×456 | 280×239.56 | 212.44 |
| Coverless panel: 360×144 or 280×144 | No cover or WebKit | Full 144 |

The prompt/tool description now distinguishes logical CSS pixels from native
points. The demo reads current production grid dimensions. No cover is rewritten,
regenerated or migrated; fixed-pixel and percentage-based existing HTML share the
same logical viewport. Cache keys remain sufficient because every poster now has
the same logical dimensions, even when reused between Overview and the panel.
Intentional author whitespace or an independently malformed composition is not
removed by this fix.

## Local evidence and limits

Baseline: detached `f5f305de`. Validation used this worktree's compiled production
objects, copied local Swift dependency checkouts/artifacts (no shared build writes),
and isolated temporary apps without Runtime or live profile access. The probe
used `orderFrontRegardless`, never app activation, and terminated only its own
process. No live app, voice mode or user document was changed.

- Production `swift build --product Mokusei --disable-sandbox
  --disable-automatic-resolution -j 4 -Xswiftc -warnings-as-errors` passed.
- `go test ./internal/plugins/applications/report` passed; `make lint` passed
  architecture/static-registration/no-Node checks, formatting and Go vet.
- `demos/super-thread-carousel/build.py --skip-build --headless` passed, including
  compilation/signing and production projection exports. Headless export alone
  does not certify visual layout.
- The separate geometry replay mounted real `NativeReportCard`,
  `NativeReportCollection` and the demo's percentage-layout `ReportFixture` in
  AppKit. It measured WebKit bounds, CSS viewport/body rectangles, converted native
  display rectangles and cached-poster dimensions; saved WebKit and AppKit bitmap
  captures; and covered both palettes, the widths above, and 144pt coverless cards.
  Fixed and responsive documents now retain a 360×308 CSS viewport. Native display
  sizes match the table, with normal subpixel rounding under 0.25pt. Warm remounts
  across widths retain 360×308 posters. Coverless cards mount no WebKit.
- Existing real-model samples were reused unchanged, without a model request.
  Their light/dark rendered compositions were inspected. This validates samples,
  not arbitrary generated HTML. Authored padding remains visible.
- ScreenCaptureKit reports no screen-recording permission. WebKit snapshots and
  AppKit bitmap/geometry evidence are available; continuous WindowServer frames,
  physical gestures, actual panel opening and full animation timing are not
  certified. The full native playback suite was not run because its launcher
  activates the app; this task avoids changing the user's active voice surface.
  No full `make check`, hosted CI, push, installation or merge was performed.

The first sandboxed graphical attempt aborted during macOS `_RegisterApplication`
(exit signal 6), before cover loading. Running the same isolated probe with window
service access resolved that environment failure. Probe-only compilation mistakes
(missing callback/read-only environment injection and an internal fixture import)
were corrected before successful measurements; they were not product failures.
SwiftPM emitted read-only global manifest-cache warnings but completed compilation.

Ignored local evidence is under `.build/super-thread-cover-layout/`: `before/`
contains baseline geometry and screenshots, `after/` includes responsive/cache
measurements, and `after-final/` contains the final-pose AppKit captures.
`LayoutProbe.swift` and `run_probe.py` retain the production-linked diagnostic;
`python3 .build/super-thread-cover-layout/run_probe.py replay` reruns it after the
production build, with graphical permission. Private real-history input stays in
that ignored directory. Build, lint, Report-test and demo logs are alongside it.

The read-only remote check found a main pull-request rule and no active required
status-check rule. Existing successful/failed remote runs belong to other SHAs;
none certify this local commit. Remote state was not changed.

## Integration with the Collection panel

Read-only inspection of `095ed0bc5fe7d5cf8c747da9b6975408b1f7f3bf` confirmed its
adaptive 280–360pt columns and 456/144pt card heights. This replay mounted those
same production card sizes; it did not import or re-test the panel interaction.
The card adapts by width, so the panel's fixed heights remain valid and require no
interaction changes.

Shared files are `NativeReportCollection.swift`, Overview `README.md`, and the
demo's `README.md`, `main.swift`, `ReportFixture.swift`. The cover patch passes
read-only `git apply --check` against the panel worktree. Integrate both sets of
hunks: keep its x/x popover, navigation/action gates, coverless fixture and 456/144pt
panel heights; retain this change's `coverHeight` for the carousel, the logical
viewport renderer, and production grid sizes for Overview demo cards. Merge
Overview documentation by paragraph. No voice or onboarding file is touched.
Caller owns integration from this detached worktree into main.

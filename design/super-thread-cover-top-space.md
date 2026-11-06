# Super Thread cover top-space investigation

## Evidence and cause

The reported Overview card belongs to the report “关联执行面板：从卡片开始”
(`3697e4ed-8815-59e7-b937-f533be326ad3`). The supplied screenshot shows its
“MOKUSEI · 界面优化” label almost touching the top edge. Only this report's current
record and its scoped Report Agent's relevant create/update calls were read.
The database was opened read-only. No user history, report or running app was
changed. Private tool-call bodies are not copied into this document.

Both actual authored cover versions were available in the retained local tool
journal, rather than inferred from the screenshot:

| Version | Tool call (2026-11-06, UTC) | Relevant CSS | SHA-256 of cover HTML |
| --- | --- | --- | --- |
| First | `create_report`, 11:40:12 | `padding:24px` | `4dc8be4f1a3e3096f25a664f357e0bdf95d469bcfd81b5dfeabb545c7ade8db6` |
| Updated | `update_report`, 11:44:20 | `padding:0 24px 24px`; `--mokusei-html-top-space:24px` | `460faa09db196605a6b82091d3d50c8e3d44a2902ecc68a8ce38e51e8194da7f` |

Both are HTML/CSS canvases with a `width:360px; min-height:308px` content wrapper,
not raster images. Their nominal aspect ratio is 90:77 (about 1.169). The updated
cover kept the same composition and changed its status note. Crucially, it also
replaced physical top padding with the Report host's top-space variable.

[Report instructions](../internal/plugins/applications/report/instructions.txt)
describe that variable and the direct `main[data-mokusei-html-content]` wrapper.
The [reader host](../app/macos/Sources/Host/ApplicationHost/NativeApplicationHTMLSurface.swift)
reserves `max(window safe area, authored top space)` on that wrapper. Before this
fix, the [passive cover renderer](../app/macos/Sources/Plugins/Applications/Report/NativeReportCover.swift)
served the author's HTML verbatim without applying the variable. The declaration
therefore did nothing, leaving the updated label at y=0 instead of y=24. This
explains why the first version was normal and the replacement approached clipping.

## Other candidates

- **Different generation/update processing:** both tools describe the same cover
  dimensions. Both mutations use `ParseCoverHTML`, which validates passive markup
  and retains the HTML. Updating changed the authored CSS, not a crop/resize path.
- **Old size cache:** no image dimensions are stored or inferred. Updating changed
  `coverRevision` to `0f42a842-120b-5d3f-b3be-fcfcebcafdd9`. The catalog carries that
  revision; `NativeReportCover` keys its fetch by it and checks the response
  revision. The renderer compares HTML and reloads changed documents.
- **SwiftUI image fill/crop:** the cover is WebKit inside a fixed 308pt region;
  there is no `Image` or `scaledToFill` in this path. The screenshot's horizontal
  and vertical proportions agree with a 360×308 viewport.
- **Rounded corners:** `NativeReportCard` clips the shared shell at radius 22pt.
  This makes absent top clearance conspicuous, but did not remove the 24px inset.
  The authored 24px top/side clearance places the label beyond the corner arc;
  blanket card padding or changing the radius would conceal the contract mismatch.

## Repair and validation

The cover renderer now honors explicitly declared `--mokusei-html-top-space`
on the direct content wrapper. It replaces top padding with that value; it does
not add another inset. Covers without the variable retain their own layout,
including deliberately edge-to-edge artwork. The reader's 60/74pt navigation
clearance does not belong to the cover. A host script installs only this style in
an isolated WebKit content world. The sandbox now permits that host script;
WebKit still disables page JavaScript and the response explicitly sets
`script-src 'none'`. Same-origin privileges, navigation and external resources
remain unavailable. Nonpersistent storage and input transparency are unchanged.

The regression test mounts the production `ReportCoverHTML` component and replaces
the document in the same WebKit view. It checks authored padding, variable-based
padding, both together, dark appearance and a subsequent edge-to-edge document,
plus viewport/scroll geometry and continued author-script/input blocking.

Local diagnostic assets are retained under
`.build/super-thread-cover-investigation/` (ignored, not product resources).
Full report HTML and private tool bodies are excluded from committed evidence.

The actual WebKit snapshots are 720×616 pixels at 2× scale. Significant non-background
ink begins at pixel row 52 in the first version, row 4 in the updated version before
the fix, and row 52 after the fix: the lost/recovered space is exactly 48 image
pixels, or 24 CSS pixels. The repaired cover's last ink is at row 530, leaving
about 42 CSS pixels below it. Its leftmost ink is at column 48 (24 CSS pixels).
Thus the authored composition fits within the original canvas and clears the
22pt top corner radius without changing the artwork or hiding overflow.
`comparison.html` in the evidence directory presents the three native snapshots;
its rounded image corners reproduce the card's top-corner clip for comparison.

The snapshot harness compiles the production renderer portion of
`NativeReportCover.swift` directly, separately at the base revision and the working
revision, with only test visibility widened for the base renderer. It mounts no
Runtime and loads only the two selected cover documents. These snapshots cover
the actual artwork and passive WebKit boundary, not the full Overview lifecycle.

Local validation completed:

- `MokuseiApplications` target build, using copied local SwiftPM repository and
  WebRTC artifact caches after the initial network-restricted dependency fetch
  failed. The focused `swift test` command also built the application and test
  executables successfully.
- `NativeReportCoverTests`: 1 test, 1 suite, passed with no skips. The ordinary
  test process does not run AppKit's animation loop, and page JavaScript evaluation
  is intentionally unavailable. The final witness uses a trusted isolated test
  script on the next WebKit task after document-end scripts; earlier observation
  attempts failed at these harness boundaries. Geometry assertions were retained.
- Actual-artwork snapshots and pixel-bound inspection described above.
- Diff whitespace and local Markdown link checks.
- Repository commit hook `make lint`: architecture/static registration/no-Node
  checks, Go formatting and `go vet ./...` passed.

The effective remote ruleset for `main` requires a pull request and strict
`Complete coverage`. Existing remote runs are for other revisions and do not
validate this fix. No push, hosted CI, merge, complete test-suite execution or
running-app replacement was requested or performed. Integration remains the
caller's responsibility for this detached managed worktree.

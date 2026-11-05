# Direct-send feedback and Dock placement

## Recording and diagnosis

The supplied `录屏2026-11-05 19.56.55.mov` lasts 15.715 seconds.
Inspected source frames show a Report and its referenced execution with input
under the right column at 0–2s. At 4–8s the capsule is compact at the workspace
centre. Around 10s it moves right, and by 12s the resulting Agent workspace and
expanded input occupy their final columns. These are observations of the
original recording, not post-change visual verification.

The Dock previously admitted running decoration only from runtime activity and
only without an expanded composer. The pinned Thread composer therefore hid
its own pending feedback. The authored running story also began with a
three-beat prelude rather than orbital travel.

Exact continuation navigation changes the reader and composer after its receipt.
The old native column marker can disappear before the incoming reader finishes
content and auxiliary admission. Treating an absent/unprepared marker as a
central destination creates an extra trip. Retaining the outgoing Report also
leaves two native hosts capable of publishing column geometry. Finally, the
horizontal column animation used an underdamped spring, which can overshoot and
reverse even with only one target.

## Behavior and ownership

- Capturing a Thread submission immediately admits orbit feedback around the
  existing capsule; the pinned editor and captured draft retain their ownership.
  The orbit skips the authored prelude, with static dots for Reduce Motion.
- Pending feedback does not set execution activity, expose a speculative Stop,
  clear input or open a result. Failure and uncertain-receipt errors use the
  existing draft error and receipt-recovery behavior.
- `NativeExecutionContinuation` and `NativeComposerDraft.submit` are unchanged:
  uncertain retries resolve the original receipt; changed input stays blocked;
  only confirmed acceptance consumes the captured revision. Late receipts do
  not gain presentation authority over a replacement visit.
- An accepted exact continuation starts a new route even for the same Thread.
  While its destination is still absent from the catalog, its existing pending
  navigation owns feedback without changing the source or resubmitting input.
  It carries the previous column into the new route until the real auxiliary
  layout is ready. The expanded shell and face seat remain in place while the
  replacement editor awaits admission. Marker route identity excludes retained
  outgoing hosts. A missing or not-yet-attached marker is not a centre target.
- A ready layout may legitimately have no execution column (for example, a
  terminal execution or folded sidecard). It publishes that final destination
  and still waits for native travel completion before admitting the editor.
- Horizontal travel uses a non-overshooting curve and samples its presentation
  position on redirection. Existing revision/composer fences reject stale
  completions. Resize, dragging, inactive scenes and Reduce Motion settle
  directly. Geometry is fitted to the current viewport, including stacked layout.

## Sprint verification

Scope: source/state review, Swift parsing, diff/link checks and an application
product build. The final application-only `swift build --product Mokusei`
passed after integrating main's `4e7dc3d` Report-close repair. Swift parsing,
`git diff --check`, local documentation links and the repository's static lint
(architecture/static registration/no-Node, Go formatting and `go vet ./...`)
passed. The first build stopped because source edits were made while it was
compiling; subsequent builds used settled sources, and the final incremental
build completed in 14.93s without warnings or errors.
No tests were added or run; no replay, interaction fixture,
remote PR or CI was used. The original recording was inspected via extracted
frames. The fixed application has not been run for visual verification, so
rendered orbit timing, glass clipping and travel remain visually unverified.

The parallel Report-close change on local main is integrated separately; this
repair does not replace its retained split layout or sidecard fade policy.

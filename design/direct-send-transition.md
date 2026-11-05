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

- Capturing a Thread submission immediately admits orbit feedback when input is
  closed. Open input hides the orbit and any retiring dot ink; closing input
  reveals applicable feedback without waiting for editor retirement. The pinned
  editor and captured draft retain their ownership.
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

## Open-input follow-up (2026-11-05)

The supplied `pasted-image.png` shows a running Agent Thread with its input
expanded and three colored dots below it. Open input now hides running feedback
at semantic admission and masks the decoration seat immediately, so a previous
orbit's retirement cannot leak through during opening or a rapid reversal.
The guard uses `inputOpen`, not `inputPresent`: closing a Thread editor restores
applicable pending/running feedback without waiting for `inputLeaving` to end.
Send, draft, receipt, positioning and focus ownership are unchanged.

The repair started from local main `c8e1c7f`, then integrated `9e61f8f` with the
parallel focus and Report-return changes without replacing their logic. The
final `Mokusei` application-only build passed (46.92s), along with Swift parsing,
diff/link checks and the repository's static lint. A disposable native
window linked those exact production Scene/Dock/composer objects and used
memory-only state. Manual UI inspection confirmed an expanded running Thread
input without dots, and a closed running capsule with dots. The preview was
closed afterward. Both states were checked again using the final combined
production modules; no installed application or user profile was replaced.

The temporary preview initially failed to compile because macOS exposes Reduce
Motion as a read-only environment value. Removing that attempted preview-only
override allowed it to build; no system accessibility preference was changed.
Reduce Motion and rapid reversal were reviewed in code, not visually certified.
Before the parallel focus fix was integrated, an attempted simulated send did
not proceed because the preview editor did not accept keyboard/paste input.
That unrelated behavior was not modified here, and the final combined preview
was limited to the open/closed running states rather than rechecking focus.
No claim is made for visual send timing, real Runtime admission, failure or
uncertain-receipt recovery. No tests were added or run, and no replay, PR or CI
was used. The existing receipt and draft implementation is unchanged.

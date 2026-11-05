# Browser annotation through the resident Moku input

## Problem and interaction

The supplied screenshot shows a native floating description editor below a
Browser selection, alongside the existing bottom Moku composer. Annotation mode
now uses that resident composer, centered horizontally below the Browser card
using the same native destination marker, column fitting and spring as execution
Sidecards. The editor stays at the ordinary reading baseline; stacked layouts
use the shared full-width column. Ordinary Browser mode keeps its main-column
input placement.

1. Enter annotation mode with Browser's toolbar. Moku moves to the Browser
   column with a separate, ephemeral description draft. The webpage retains
   focus for element picking or region dragging; Send is unavailable until
   selection completes. Selection completion focuses Moku without another click.
2. Describe the selected area. Return/Send captures the selected webpage and
   submits its description, locator, URL/title and screenshot through the
   existing Thread-bound annotation transport. Shift+Return and Command+Return
   retain the editor's newline behavior. This submits any existing recoverable
   annotation batch and supplementary text as well.
3. Escape, the accessible Cancel annotation control or the Browser toolbar
   cancels selection/description input. Navigation, covering, closing and card
   replacement do the same. Ordinary Thread/Moku drafts and their send routing
   are restored; descriptions cannot become ordinary messages accidentally.
4. Capture failure keeps the selected operation and its text for correction or
   retry. A successful capture transfers both to the recoverable annotation
   batch and leaves selection mode. Failed runtime sends retain that batch and
   the existing Browser retry/text-only controls. Accepted receipts consume only
   their original batch, even after leaving the reading route.

Description input accepts text only and keeps the existing 10,000 UTF-16-unit
limit. File/directory/voice affordances belong to the ordinary input, not this
temporary operation. During capture the editor becomes read-only while the
explicit cancellation control remains reachable. Native IME, menu and transient
cancellation keep priority. The removed floating editor has no paint, focus,
pointer region or accessibility subtree.

## Ownership and cancellation

`SidecardView.composer` carries a typed operation ID, readiness and localized
placeholder, plus submit/cancel callbacks. Only the selected, available and
unsuppressed activity publishes one. The window owns its temporary native draft;
it retains the separate persisted Thread and Moku drafts unchanged. The resident
Dock reuses its normal editor/focus ownership and protects callbacks by draft
identity and composer generation. Runtime authority remains in the existing
Sidecard services; no application capability is exposed to webpage scripts.

The publisher is fenced to its reading visit and Thread. Browser callbacks also
check presentation/context generation, WebKit session and annotation operation
identity. Capture continuation completion is single-owner: cancellation resumes
it with cancellation; old page/title/snapshot/restore callbacks cannot complete
a newer selection. The existing DOM re-read before capture and comparison after
snapshot still reject removed or changed targets. Batch admission rejects a
concurrent annotation-limit change instead of silently dropping a description.

## Review and Sprint verification

The starting worktree and local main both contain `27f74cf` and the preceding
input-position, Report-admission and shell-clipping changes. This change reuses
the execution placement bridge and preserves those Report changes. It does not
add annotation authority to the Report's read-only linked Browser.

The supplied screenshot and production paths were inspected. The existing two
native Browser viewport cases now assert absence of the removed annotation
portal while retaining document-layer, zoom and suppression assertions; no test
cases were added. Per Sprint mode no tests or regression replays are executed.
Validation is application compilation, static lint, source/lifecycle review,
Swift parsing of the adjusted existing cases, and diff/documentation link checks.
Initial compilation hit a SwiftUI diagnostic failure; explicit callback types
and a separate help expression resolved it. No post-change running-app visual,
focus, VoiceOver or interaction acceptance is claimed. No CI, push or remote
mutation is performed; main integration belongs to the coordinator.

The final application product build, `make lint`, adjusted-case Swift parsing,
diff review and local documentation link checks passed. These static results do
not establish runtime focus, geometry, screenshot/submission or accessibility
behavior; tests and visual interaction were not run.

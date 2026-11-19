# Semantic workspace interactions

`NativeWorkspaceAction` is the typed intent boundary for window navigation.
`NativeWorkspacePresentation.performInteraction` admits actions against the
current page and calls the same presentation/Overview methods used by controls.
Settings controls and dispatch share `NativeSettingsNavigation`, including the
invalid-field focus, IME and save-on-close gate. This layer owns no Runtime
commands or independent copy of page state.

`interactionSnapshot()` reports the semantic route, mounted reading/settings
surface, navigation animation activity, settings save state, filter and
thread identities, available action names and errors. Overview camera observations
contain ordinary framing, viewport, motion and pause facts; they expose no
automatic per-card target. `settings.appearance` and
`settings.locale` report the saved client preferences even when Settings is closed
or the Runtime is unavailable. Thread targets are the current Overview projection;
stale or filtered-out targets are rejected.
Available actions are advisory: dispatch checks current state again. A successful
call means the intent was applied; it does not mean SwiftUI has rendered a frame,
an animation has ended, or settings persistence has completed. Settings opening
and return both report `transitioning`; return keeps the Settings route mounted
until the capsule finishes contracting. `settings.open` is available only on a
loaded Overview; other routes reject it without navigation.

Moku history reports its shared reading-panel motion as `transitioning`, stays
mounted until Close completes, and uses a separate navigation action from its
retained parent. `navigation.back` first follows internal historical-turn
navigation, then closes history without losing the parent's reading target.

Direct Swift callers can use, on the main actor:

```swift
try presentation.performInteraction(.openSettings)
try presentation.performInteraction(.selectSettingsSection("general"))
try presentation.performInteraction(.closeSettings)
let state = presentation.interactionSnapshot()
```

The macOS App's opt-in Unix socket validates external request envelopes and action
arguments before dispatch. The macOS App owns transport outside the presentation
module.

`settings.control` addresses a mounted control ID and observed handle, then
invokes the registration owned by that control. `settings.controls` includes
current values, options, enablement, validation, composition and notices; save
status/revisions are separate. The page injects the registry into production
components, so script actions execute their real callbacks rather than assigning
to a settings JSON path. See the protocol guide for operation/value types and
stale-handle behavior.

`reading.control` addresses `reading.controls` with the same owner/handle pattern
through `NativeReadingInteraction`. The window supplies its navigation visit to
production conversation components, suppresses retained hidden controls, and
admits commands only while the selected thread page is mounted. Internal history
transitions, content-resource states and geometry are observed by the mounted
components; the Host does not decode a Harness timeline or mutate its data.

A Settings return retains the page only for capsule animation. While `settingsClosing`
is true, section selection and mounted-control mutations are unavailable, so a
rapid caller cannot receive a success for a page that is already retiring. Close,
Back and Overview remain available.

First-run setup reports `page: "onboarding"` and an `onboarding` object containing
step (0–4), admission, editor readiness, continuation availability, save/error
and persisted completion state. Only its mounted `settings.control` actions are
admitted, using an independent visit/step registry. The handoff reports
`transitioning` until the real Dock is revealed; workspace navigation remains
blocked throughout setup and the morph.


Super Thread collections expose every real member as a `thread.open` target.
Overview card observations include `members` and the currently displayed member's
`ref`/`title`; the synthetic collection identity is only a canvas slot. Opening
uses the same source/return geometry resolution and profile-local reading fact
as native card activation. Selecting a carousel page is not a reading event.


Individual report observations expose `collectionEligibility`. Collections expose
the same fields per real member in `memberEligibility`. `lastClosedAt` and
`lastQualifiedAt` use epoch milliseconds or null. `defaultsToCollection`
describes the reading history and `collected` the current space's projection.

## E2E contract

[`E2E-READ-001`](../../../../../tools/e2e/README.md) uses these real navigation
callbacks and mounted reading registrations. Preconditions are an isolated
connected workspace, a completed Codex Thread prepared through public Moku
input, a private automation socket and an exclusively scheduled desktop.
The runner opens the Overview target, observes its ready nonempty `turn`,
supplies a public Runtime follow-up, observes the mounted successor, activates
the initial `history.open` handle, then uses Back and Overview. Each selected
execution must match the corresponding public scoped output identity. Required
evidence is `ui-initial/current/history/return/overview.json` plus the public
content and UI request/response transcript.

This checks navigation, resource acquisition and mounted semantic content. It
cannot establish pixel appearance, text geometry, pointer hit regions, keyboard
routing, scroll smoothness or composer submission. A successful dispatch is
insufficient without the settled mounted postcondition. A missing desktop,
control, content or evidence yields a nonpassing receipt; this doc does not
certify an unexecuted scenario. The public protocol has no composer send/pause
operations. [`E2E-COMPOSER-001`](../MokuScene/README.md#e2e-contract) uses
operator-assisted system input with separate public result oracles.

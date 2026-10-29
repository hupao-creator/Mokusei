# Semantic workspace interactions

`NativeWorkspaceAction` is the typed intent boundary for window navigation.
`NativeWorkspacePresentation.performInteraction` admits actions against the
current page and calls the same presentation/Overview methods used by controls.
Settings controls and dispatch share `NativeSettingsNavigation`, including the
invalid-field focus, IME and save-on-close gate. This layer owns no Runtime
commands or independent copy of page state.

`interactionSnapshot()` reports the semantic route, mounted reading/settings
surface, navigation animation activity, settings save state, search, filter and
thread identities, available action names and errors. `settings.glassWorld`
reports the current client preference even when Settings is closed or the Runtime
is unavailable; mounted General controls expose `general.glassWorld`. Thread targets are the
current Overview projection; stale or filtered-out targets are rejected.
Available actions are advisory: dispatch checks current state again. A successful
call means the intent was applied; it does not mean SwiftUI has rendered a frame,
an animation has ended, or settings persistence has completed. Settings opening
and return both report `transitioning`; return keeps the Settings route mounted
until the capsule finishes contracting. `settings.open` is available only on a
loaded Overview; other routes reject it without navigation.

Direct Swift callers can use, on the main actor:

```swift
try presentation.performInteraction(.openSettings)
try presentation.performInteraction(.selectSettingsSection("general"))
try presentation.performInteraction(.closeSettings)
let state = presentation.interactionSnapshot()
```

The macOS App's opt-in Unix socket validates external request envelopes and action
arguments before dispatch. The macOS App owns transport outside the presentation
module. See the [script/protocol guide](../../../../../tools/native-interaction/README.md)
and [real app replay](../../../../../tools/verification/native-interaction/README.md).

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
Back and Overview remain available. The production navigation replay exercises
this rejection immediately after initiating Back without waiting for animation.

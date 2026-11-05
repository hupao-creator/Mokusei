# Execution composer focus (2026-11-05)

## Recording and production chain

The supplied `录屏2026-11-05 20.59.46.mov` is 7.933 seconds long. It shows
an Agent reading page, selectable body text and repeated visits to the visible
bottom composer without a visible insertion point. It does not include the
preceding current/history switches or typed text. The recording alone cannot
prove which control was first responder, whether its window was key, or whether
the editor was still unavailable.

The actual route is:

1. `ThreadConversation` publishes the selected execution, follows-latest policy
   and inner reading-motion readiness through `ThreadConversationInputTargetKey`.
2. `NativeAgentThreadWorkspace` forwards that owner-scoped preference to
   `NativeWorkspacePresentation.updateAgentInput`. The Shell selects the
   window-owned current Thread draft or exact Thread/execution draft and calls
   `NativeMokuSceneState.setComposerContext`. TOC navigation suppresses automatic
   focus so the reader/history rail keeps keyboard ownership.
3. The resident Dock survives navigation in `MokuHorizontalTravelView`'s native
   hosting tree. Its compositor absorbs pointer hits during column travel;
   arrival releases that protection. The scene's primary entrance and the
   selected reader's readiness independently gate interaction/send admission.
4. `NativeMokuComposerInput` mounts `NativeComposerTextInput`; its SwiftUI request
   is applied by `NativeComposerEditor.updateNSView` to the actual editor's
   `NSWindow.makeFirstResponder`. The editor's coalesced native state report
   updates SwiftUI. A first responder in a background window does not make that
   window key: the custom caret also requires `window.isKeyWindow`.

## Confirmed breaks and repair

The Dock used its 180ms autofocus readiness flag as native `focusEnabled`.
After a draft/context change the flag resets. A click/Tab accepted by AppKit
before readiness could therefore trigger a SwiftUI update which explicitly
cleared that same first responder. Readiness is now generation-scoped and
controls automatic requests only; admitted native interaction has no additional
autofocus-delay gate. Retiring/covered/unavailable controls retain their gates.

The shared text input keyed its request task only by request number/context.
A request arriving while unavailable was discarded, with no retry when reading
readiness or submission availability settled. The task now observes eligibility
and consumes an eligible request once, so passive availability changes do not
replay an already consumed intent or continuously steal focus from the reader.

For a pinned Agent composer, Compose previously attempted to fold the editor;
that action is intentionally refused. After TOC navigation suppressed autofocus,
Cmd+Shift+B thus did nothing. Compose now issues an independent explicit request,
fenced to the selected composer generation. It does not change draft identity,
submission generation or receipt ownership. Ordinary TOC selection still does
not autofocus. Moku history/camera return keeps priority over pinned input.

The send, draft consumption and execution continuation implementations are
unchanged. Failed/uncertain sends retain their existing draft and protected
receipt; focus requests neither retry commands nor consume input.

## Verification scope

Sprint mode: no new tests, test suites, regression runners, remote PR or CI.
Only the existing read-only multi-turn data generator was used to seed a new
`/private/tmp/moku-focus-manual-profile`; no replay runner was invoked and no
user profile was copied. The manual app contains this worktree's actual Mokusei
application product, Runtime, resource bundle and WebRTC framework, under a
separate app identity. It uses an ad-hoc local signature, rather than a production
signed distribution. Temporary native focus logging was removed before the final
build and is absent from the commit.

Before the fix, Computer Use confirmed that selecting historical turn 1 and
pressing Cmd+Shift+B left AX focus on the window and typed text did not reach the
composer. Settled pointer clicks after current/history switches worked in this
isolated baseline; the original persistent pointer failure was not reproduced.
The source chain above identifies the entrance-time click cancellation and lost
request independently; do not describe it as an exact reproduction of every
condition in the user's recording.

Final build, manual observations and evidence are recorded below after review.

Final observations on the repaired application product:

- Historical turn 1 remained in reader/window focus after selection. Cmd+Shift+B
  then focused the editable native AX element; `history-keyboard-ok` appeared in
  that exact-execution draft. Repeating the command across another current/history
  switch also acquired the editor. Text sent before the reading transition became
  eligible was not buffered; typing after the ready observation worked.
- Returning to current restored `current-draft-clicked-pointer2`. Clicking the
  actual bottom editor coordinates and typing appended `-final-pointer-ok`.
- Returning to historical turn 2 restored its separate `-pointerhistory-draft`;
  a coordinate click appended `-history-pointer-ok`. Turn 1 retained its own
  `history-keyboard-ok` text. No send was performed.
- Shift+Tab did not produce an observed focus move in this environment and is
  not counted as a passed keyboard-navigation check. The keyboard-focus evidence
  above is the application's explicit Cmd+Shift+B route.

Evidence is retained in the worktree's ignored `.scratch/execution-focus-evidence/`:
`moku-focus-keyboard-after.{txt,png}`, `moku-focus-pointer-after.{txt,png}`,
`moku-focus-history-pointer-after.{txt,png}`, `moku-focus-repeat-settled.txt`,
`recording-contact.jpg` and `final-build.log`. AX snapshots include both the
selected turn and the focused editable element, in addition to the text markers.
The independent app was closed afterward; the user's existing app and concurrent
worktrees were not changed.

The final application build completed successfully in 27.39s using:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/moku-swift-module-cache swift build \
  --package-path app/macos --scratch-path .build/moku-focus-swift \
  --cache-path /tmp/moku-focus-spm-cache --product Mokusei
```

Application executable SHA-256:
`c4d1e9a393799484c2d5c926c37e6377d1658c32e2a7b2abfb015f6658dddf8d`.
The preceding build was incomplete because a review edit changed an input while
it was compiling; only the subsequent complete final build certifies the source.
Initial sandbox attempts also could not launch the SwiftPM manifest sandbox or
AVFoundation decoder. The allowed unsandboxed build/decode commands succeeded.
Diff whitespace and changed-document local links were checked; the unrelated Go
lint hook, test targets, regression runners and remote checks were not run.

Computer Use targets app windows in the background. Temporary native logs showed
successful first-responder acquisition with `isKeyWindow == false`; therefore AX
focus/text and actual app-window screenshots are the observations established
here. Foreground key-window activation, a visible live caret, physical pointer/Tab
behavior, IME and new running execution/Sidecard transitions were not certified.
No actual model task or uncertain-receipt send was exercised. Existing failure
and receipt behavior was reviewed at its unchanged production boundary. Neither
the successful build nor these bounded manual observations prove every condition
in the original recording has been reproduced and eliminated.

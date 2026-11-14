# Agent detail entry orbit

## Recording and cause

The supplied `录屏2026-11-14 16.10.38.mov` is 13.173 seconds long. Sampled frames
around 1.98–2.63s and 7.25–7.90s show three colored dots around the compact Dock
while an Agent execution reader is opening. The expanded editor is visible
without dots by 3.29s and 8.56s. Overview before and after those visits has no
dots. These are observations of the supplied recording, not a repaired-app replay.

The workspace selects the Agent draft and calls `setComposerContext` with
`keepsInputOpen: true` and `waitsForHarnessIdentity: true`. Reading arrival admits
the identity flip; its generation-fenced completion opens the editor. Until then,
`inputPinnedOpen` is true while `inputOpen` is false. The Dock's running-feedback
gate previously checked only `inputOpen`, so applicable active Thread status
could start its immediate orbit during this preparation interval. This is running
feedback, not a page-loading indicator or a horizontal-travel effect.

The decorations host also hid only for `inputOpen`. Merely rejecting a new orbit
would still allow a previous running pose's retiring dots to leak into entry.

## Repair contract

- Open input or persistent Agent input ownership suppresses running feedback
  and immediately hides retiring decoration ink, even before editor admission.
- The existing composer ownership and generation fences govern close and rapid
  route/Thread replacements; no timer or second navigation state is introduced.
- Ordinary and exact-execution Agent inputs, including Report's borrowed input,
  share this rule. Sidecard input remains under the same persistent ownership.
- Closing detail returns feedback ownership to the destination composer. Only
  that destination's applicable running/submission state can request an orbit.
- Ordinary closed-input Moku/Thread feedback, Reduce Motion's static dots,
  submission receipts, running status and Send/Stop authority remain unchanged.
- Horizontal travel, rebound, Harness flip and the authored running story are
  outside this repair. No new tests are added under the requested sprint scope.

## Validation scope

Review follows workspace composer selection, reading admission, identity
completion, open/close and replacement fences, and both the semantic feedback
gate and retained-ink visibility gate. Focused headless compilation and existing
related windowless cases are the local verification scope. This does not certify
WindowServer pixels, actual animation timing, pointer/focus behavior, real
Runtime sends or rapid manual navigation in the repaired application. No push or
hosted CI is part of this sprint delivery.

Local results on 2026-11-14:

- `xcrun swift build --package-path app/macos --product Mokusei
  --force-resolved-versions --disable-index-store -j 2` passed in 136.19s.
- With `MOKUSEI_TEST_HEADLESS=1`, the existing `NativeThreadSendFeedbackTests`
  methods `pendingSendCannotStealANewerReadingChoiceOrRevealAnInvalidExecution`,
  `activeExecutionEntryIsExactAndClosingIsRememberedForTheVisit` and
  `completionHandoffRetainsIdentityUntilTravelAndDestinationAreReady` passed:
  3 methods, 20 parameter cases, zero failures/skips. The test build took 82.46s;
  execution took 0.379s. These check surrounding lifecycle contracts, not the
  new decoration visibility rule or rendered orbit pixels.
- Diff whitespace and the new README link passed local review. Code changes are
  confined to the Dock's feedback and ink gates; no travel/rebound code changed.
- Initial sandbox attempts could not decode the recording or launch SwiftPM's
  manifest sandbox. Retrying those read/build operations with normal host
  permissions succeeded; these were environment failures, not product failures.
- The GitHub read-only audit found no traditional main branch protection and an
  effective ruleset requiring PR review-thread resolution, with no required
  status-check rule. The one open PR and recent runs were complete. Their older
  results do not certify this change. No remote write or CI dispatch was made.

Local extraction/build/test evidence is under
`/tmp/expanded-page-orbit-evidence/`. The repository-wide Go pre-commit lint and
full/native regression runs are outside this explicitly focused sprint scope.

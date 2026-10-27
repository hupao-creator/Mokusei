# Note exposure implementation handoff

2026-10-27. Continued the existing uncommitted implementation on detached
`d42733a4a`; integration into main belongs to the coordinator. No push.
Design: [note-read-awareness.md](note-read-awareness.md).

The Runtime retains one exact server-owned exposure snapshot and a separate
reading CAS counter. The UI certifies only complete foreground viewport coverage
of the applied incarnation/revision, with two-second stable intervals. Opening
or replacing the visible note does not acknowledge it. Unsupported Markdown stays
unknown. The Agent receives current text, exact prior exposed text and a CAS basis;
stale writes return the latest snapshot for reconsideration. Exposure never means
understanding, approval or permission to discard still-useful decisions/work.

Review fixes retain a completed receipt across same-version rehydration, cancel
retired requests, discard obsolete pending receipts, and merge settled intervals
instead of accumulating repeated visits. Workspace release revokes submission
authority. Protocol versions were synchronously advanced from 10 to 11.

## Replay isolation incident

The previous launcher placed its app in a temporary directory but passed Desktop
fixture/evidence paths and launched from the Desktop checkout. Its `open -W`
timeout did not terminate the separately launched app. These paths could request
Desktop TCC access and leave a blocked app behind. A remaining old app-server
also continued its child work after the parent thread had been interrupted.
The exact task-owned replay, launcher and old app-server received SIGTERM;
the user's main application was left running. No permission buttons or TCC
settings were changed.

The shared native launcher now copies fixture, replay source, linked objects,
modules, headers, framework and resources into a unique temporary workspace.
Only the Python launcher exports evidence to the checkout after the app exits.
The app checks its input/output/cwd/resource paths before mounting UI and records
its PID. Launches are locked, logs and paths are retained, and timeout/cancellation
retires only the matching staged executable. The Go launcher uses cooperative
interrupt before its wait deadline. Talk dismissal and reading-presentation use
the same isolation boundary. See [replay instructions](../tools/verification/moku-note/README.md).

## Verification and limits

- `make check ARGS=` passed on the final product changes, including architecture,
  Go format/vet/build, Swift build, concurrency properties and module/tag checks.
- Race-enabled Moku, command-boundaries and transport replays passed.
- Two complete isolated native Note runs passed, including short-note dwell,
  in-place updates, unsupported Markdown, long-note gaps and complete traversal.
- The real Swift tracker/sender → authenticated Runtime → durable exact text →
  next Moku context replay passed. Isolation manifests confirm temporary paths;
  no TCC prompt was observed in these successful isolated runs.
- Talk dismissal passed with the new unknown-exposure assertions, including its
  real 60-second expiry. Reading presentation passed all five native cases.
  Two Swift Note contract/authority tests and Python syntax checks passed.
- A controlled five-second Note timeout returned the expected failure, retained
  a bootstrap PID and cleanup diagnostics, and sent SIGTERM to that exact app.
  A process check confirmed the PID and all task-owned replays were gone. An
  earlier one-second timeout preceded bootstrap and was not counted as proof
  of GUI cleanup. No permission approval was used during these checks.

Local evidence is retained under `.scratch/note-read-awareness` and deliberately
excluded from the commit. The first full check was invalidated by concurrent
source edits and rerun successfully. Pre-isolation native attempts failed on
foreground eligibility while permission prompts were present; they are not
counted as passes. Isolation preflight failures were diagnosed before mounting UI.

This certifies presentation, not gaze or cognition; partial occlusion and
VoiceOver reading progress remain unknown. Code/tables/images/local previews do
not produce complete evidence. Late receipts for replaced text are conservatively
dropped. Native voice uses fixtures with motion disabled; Reduce Motion and live
media continuity are source-reviewed. No live model/provider, microphone or fault
injection of an OS/SQLite commit failure was exercised, and fixed provider inputs
cannot prove every future model will summarize correctly.

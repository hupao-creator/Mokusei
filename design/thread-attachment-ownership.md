# Thread attachment ownership investigation

## Recording and persisted evidence

Source: `录屏2026-11-04 18.47.16.mov` (10.373 seconds), supplied from the
Native Dev profile's attachment directory. Frames were decoded into temporary
files; the profile, recording, attachments and drafts were read only.

- At 0s, Overview shows “集成线程详情逐行显现时机修复”.
- By 2s, its Agent reader is open. Around 3–4s, the bottom Agent input capsule
  expands with an image chip and an enabled Send action. The chip is in the
  unsent composer, rather than the transcript or execution Sidecard.
- By 6s, the reader has closed and Overview is visible again. The recording
  does not show the original paste or a transition between two distinct IDs.

The profile's persisted draft narrows the interpretation further:

- The displayed Thread is `cac0eed4-eb33-44e4-86c9-ecc4ea3ff990`.
- Its `thread-detail:<id>` draft contains one ready `pasted-image.png` chip,
  staged as `4dea9515-92dc-4748-8118-7595a4cafabd`. The file creation and draft
  modification times are both 18:38:27 local time.
- That image shows the input placeholder “发送给「安全集成报告线程修复至本地
  main」…”. Runtime events show that **the same Thread ID** acquired that title
  at 18:38:14, then “集成悬浮栏占位文字截断修复” at 18:40:53, and the recorded
  title at 18:46:50.

Thus this recording establishes restoration of an earlier unsent attachment
after successive tasks retitled one Thread. It does not establish that those
tasks had different Thread identities. Deleting the chip on title/execution
changes would destroy a real saved draft. No existing draft or staged file is
removed or migrated by this repair.

## Ownership boundaries and repair

The window retains separate `NativeComposerDraft` objects for Moku and each
Thread ID. Persistence hashes the complete scope and verifies that scope when
loading. Title and execution changes deliberately retain the Thread's draft.
Reader prefetch/idle content caches select by Thread ID and content scope;
they do not populate composer attachment arrays. Preview completion captures
the original draft and matches an existing chip ID. Import/staging and send
receipts likewise remain with the submitting draft across navigation.

Source review found two other boundaries that could cross owners:

1. `NativeComposerPasteShortcut` walked upward through native containers to
   find an editor whose center overlapped its bounds. A retained or covered
   composer in the same window can overlap another editor. Its monitor could
   then claim that editor's paste and start provider decoding/staging against
   its own draft. A mounted `NativeComposerTextInput` now supplies one stable
   UUID to both its native `ComposerTextView` and shortcut monitor. The monitor
   requires that exact first-responder identity before reading the clipboard.
   It cannot claim an unrelated native text field or sibling composer through
   common ancestry or geometry. Native paste, IME and text-only handling retain
   their existing paths.
2. The scene's shared retiring-ink snapshot accepted any draft. An old mounted
   Dock callback, including an attachment/import update after navigation,
   could overwrite the newly selected owner's retained text, directories and
   chips. `retainDraft` now admits only the scene's current composer identity,
   using the same ownership boundary as focus, send and selection callbacks.
   Old imports still finish in their original retained draft; they cannot
   replace the current capsule's snapshot.

These are source-level routing defects repaired independently of the saved
draft observed in the recording. Neither has been reproduced dynamically in
this sprint, and neither should be claimed as the proven cause of that image.

## Verification and limits

Per sprint instruction, no tests are added and no tests, regression replays,
application builds, hosted CI, push or PR creation are performed. Verification
is limited to reviewing the final diff and callers, Swift frontend parsing of
the four changed source files, whitespace checks and the new documentation's
local links. The normal pre-commit hook's repository-wide Go lint is omitted
for this scoped Swift-only static check.

Remote protection, open PR and main-run queries were attempted with `gh`, but
the environment could not connect to `api.github.com`. No remote gate status
is asserted. The detached commit is handed to the caller for local integration;
these checks do not certify mounted paste routing, interrupted navigation or
async attachment behavior at runtime.

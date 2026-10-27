# Talk dismissal and capsule edge replay

```sh
make check
python3 tools/verification/moku-talk-dismiss/run.py --skip-build
```

Mounts the production Dock in an isolated nonactivating NSPanel, with the reported
Chinese notification and an unread note. Captures its real WindowServer pixels
using ScreenCaptureKit into `.scratch/moku-talk-dismiss/evidence`.
The `centered-*` captures also show Chinese and English single-line and multiline
messages for visual alignment review, including the reported short notification.

The replay sends native AppKit mouse events to the panel and a second NSWindow:
inside click/scroll retains the message, outside click dismisses without consuming
the target's click, catalog-equivalent redelivery stays dismissed, and a new message
appears. It also checks detach/remount and preserved note opening/read tracking.
Opening the note keeps its unexposed indicator until the authoritative catalog
contains full-viewport evidence; Talk dismissal never changes that evidence.
It waits for the production 60-second deadline, checks that refresh retains that
deadline, verifies automatic dismissal and no resurrection on remount, then
checks a fresh message receives a new deadline.
`report.json` records the checks and limits. No live runtime, provider or microphone
is started. Cross-app global mouse delivery is not injected by this replay.
The shared [native launcher](../native_replay.py) copies sources, build artifacts,
resources and evidence output into a temporary workspace, then exports results
after the GUI process exits. The app validates those paths at startup and records
its PID for timeout/cancellation cleanup. Desktop access is not needed.

The older `moku-talk` replay currently references the removed
`NativeMokuTalkScrollView`; this focused replay uses the current SwiftUI production
content and does not claim to validate that older audit/dispatch suite.

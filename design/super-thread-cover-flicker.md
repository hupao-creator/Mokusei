# Super Thread cover flicker on tag switching

## Recording and cause

The user recording `录屏2026-11-12 12.02.28.mov` switches from the Mokusei
filter to All and back. AVFoundation extraction of exact transition frames shows
empty cover regions at 1.383s, three white cover rectangles at 1.450s, and the
authored covers again at 1.500s. This is filter navigation, not carousel paging.

Overview deliberately gives each type/filter collection a distinct canvas identity.
Changing filters therefore remounts its Report covers, even when reports and their
cover revisions survive. Previously each mount discarded the fetched document,
created a new WKWebView and displayed it immediately, exposing WebKit's initial
backing store before the authored HTML/CSS painted. Ordinary cards that survive
as the same canvas identity do not follow that remount path.

## Fix and ownership

The Report plugin registration owns a bounded, memory-only cache of at most 16
cover documents and rendered images. The key includes the full HTML source
(report reference and independent cover revision) and light/dark appearance.
It is not global or shared between workspace/plugin registrations. The standalone
carousel demo supplies the same scope at its root.

A remounted cover starts synchronously with its exact cached markup and pixels.
Its replacement WebKit surface stays hidden until a successful load has produced
a native snapshot. The rendered image remains underneath the live WebKit surface:
local rapid-switch capture found that clearing it immediately at the snapshot
callback could expose a one-frame gap before WebKit's native layer committed.
The live document still renders normally, including authored CSS; no timer or
fade substitutes for loading readiness.

Only markup and images survive card lifetimes; no browsers are cached. Existing
four-browser collection mounting limits, input transparency, CSP, blocked script /
external-resource/navigation policy and view cancellation remain in place. Errors
clear that entry and retain the native unavailable presentation. A new revision
or appearance cannot borrow a previous key's image. Cold entries use the ordinary
loading presentation until their own document renders. No report records,
attachments, reading evidence, preferences or other user data are written.

## Local evidence and limits

Baseline: detached `ae1d805ad51f2dddfe39f908203b4fb5bfba3c72`. PR #303 is a
descendant at `db81a349114696316d5ae237a99c1c2379abf5ab`; its settings and replay
changes are outside this fix and were not rewritten or incorporated. Remote main
was `5abb5c2b111780c5094b8096139bf9edc8cd033d` when checked. PR #303 was open,
with successful Complete coverage; that result does not certify this new change.
The actual main rules exposed a PR requirement, no traditional branch protection
and no active required-status-check rule. No remote state was changed.

Focused verification uses the current worktree's real NativeReportCover and
NativeReportCollection in a separately signed temporary app, deterministic
existing Report fixtures and only that app's own ScreenCaptureKit window. It
covers dark/light tag identity replacement, return, collection/single cover
handoff and rapid replacement. This is a production-component replay, not a run
against the user's live Runtime/profile, physical tag clicks or a full application
regression suite. No new tests are added.

Final-source results (macOS 26.5.1, arm64, Swift 6.3.2):

- `swift build --product Mokusei --disable-sandbox --disable-automatic-resolution
  -j 4 -Xswiftc -warnings-as-errors` passed. An earlier attempt failed because a
  source adjustment overlapped compilation; the completed final build supersedes it.
- The existing `demos/super-thread-carousel/build.py --skip-build --headless`
  export passed against final production objects, including signing/strict signature
  verification, without creating NSApplication or touching a live profile.
- The isolated native replay captured 162 full-size 840×1040 WindowServer images.
  All warm identity replacements, returns and collection/single handoffs retained
  the authored cover background in the sampled region. The two initial light-theme
  loading samples belong to a cold appearance key, not a cached-cover regression.
  Representative frames were also inspected visually for authored content and geometry.
- A 60fps-configured ScreenCaptureKit stream during 24 further identity changes
  delivered 23 complete update frames; all retained the exact authored background
  region, with no failed/blank/white sample. This reports delivered changed frames,
  not a claim of 60 distinct frames per second or a physical input replay.
- Local diff/Markdown-link review passed. The commit hook runs repository lint.
  No new test cases, full local `make check`, hosted CI, push or merge are included.

Local ignored evidence is retained in `.build/super-thread-cover-flicker/`, including
build/capture logs, the temporary replay source, all captured frames, pixel summaries,
stream timestamps and the headless exports. The earlier one-frame handoff failure
is retained separately under `/tmp/mokusei-cover-flicker/native-first/` for diagnosis;
it was fixed by retaining the rendered underlay rather than weakening the pixel check.

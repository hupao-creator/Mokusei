# Native code block clipping

The reported completed Thread, “完善智能体发现与配置预加载”, shows two shell
commands cut off at the right code-block edge. Read-only inspection of the local
completion evidence confirmed both commands are complete, including
`--scratch-path .build/swift -j 2` and `--filter NativeSettingsDiscoveryTests`.
No conversation or persisted reply was changed.

## Rendering boundary

`ThreadMessage` renders the settled reply through `NativeMarkdownView`.
`MarkdownBlockView` routes fenced/indented code to `MarkdownCodeBlock`.
The renderer is SwiftUI plus AppKit/TextKit, not HTML or WebKit.
`NativeMarkdownCodeMetrics` measures the longest source line; the TextKit view
keeps that natural width. The reading column remains bounded by the timeline,
and nested lists subtract their marker width before laying out their blocks.

The code is intentionally unwrapped. Its offscreen tail must be exposed by a
horizontal code viewport rather than by the outer page. The old wrapper put a
fixed-width native text view inside SwiftUI's horizontal `NativeScrollView`.
The screenshot alone cannot establish whether that viewport accepts gestures.
In the never-displayed production-component probe, its document was wider than
the clip and its text storage was complete, but the native scroller reported a
zero knob proportion. Moving the clip directly reached the tail; synthetic
wheel input did not advance it. This is presentation/scroll reachability rather
than source truncation; it is not evidence that a visible-window gesture was
reproduced.

## Change

The fence now owns its native document and horizontal scroll view together,
using the existing `NativeStyledScrollView`/`NativeScrollbarStyle` policy.
The SwiftUI representable reports only the proposed reading width and the
complete text height plus native persistent-scroller gutter. Its document owns
the measured line width and unchanged 16pt padding. This avoids depending on a
second SwiftUI scroll document to reconcile an oversized native text child.
Native clipping, scroller tracking, selection and accessibility share that
document geometry. Source shrink clamps the retained offset through AppKit;
ordinary source updates preserve selection and scroll position.

Source lines, monospace typography, code background and Copy Code remain
unchanged. Copy Code receives the original source; native selection exports the
displayed source with the existing one-terminal-newline omission. No soft-wrap
characters enter storage. Inline code and tables retain their existing paths.
Ordinary vertical wheel events pass to the reader; horizontal and Shift-wheel
events stay with the code viewport. Scroller preferences remain system-owned.

## Sprint verification

No tests were added. Local verification uses the current detached worktree,
`MOKUSEI_TEST_HEADLESS=1`, and never orders a window or starts/restarts Mokusei.
The temporary production-component probe and raw logs live under
`.build/markdown-evidence/`; they are not product or test-suite sources.

The probe checks the reported two-line block, a 500-character unbroken token,
blank lines/tabs/Unicode, a list-nested block and long inline code at 900, 600,
280 and 120pt widths, with process-local overlay/persistent scrollbar settings.
It checks bounded outer width, unwrapped complete text, native knob proportion,
right-edge reachability, selection reveal/export through an independent named
pasteboard, vertical wheel forwarding, unchanged-source offset retention,
native resize and source shrink. It does not touch the general clipboard.

Final results on 2026-11-17:

- Swift `--build-tests` completed successfully (final incremental build: 16.12s).
- The existing source identity, source range, fallback source, table rewrite and
  native line-cache selections passed: 22 tests in 5 suites, no skips.
- Both scrollbar processes passed all 20 width/content combinations (40 total),
  plus one mounted width/source/UTF-8 replacement sequence each. Every diagnostic
  window remained invisible. A 552pt code viewport retained a 1038pt document,
  a 486pt horizontal range and a 0.532 native knob proportion; legacy mode also
  reserved its 13pt gutter outside the full 73pt code document height.
- Diff whitespace and changed-document local links passed review. Changes are
  confined to the shared code viewport and its documentation; Overview card
  geometry and the concurrent feature modules are untouched.

Build/test commands and measured outcomes are recorded with the delivery.
The initial restricted SwiftPM build could not create its nested sandbox;
the authorized build ran successfully outside that restriction. Selection export
also needs the pasteboard service outside the restricted sandbox. Early probe
iterations used an unsupported pasteboard format and incorrectly targeted the
last short line when checking horizontal selection reveal; the final probe
uses the native advertised format and the longest line's tail. The early shrink
fixture also still overflowed the narrowest nested viewport; the final fixture
uses a source that actually fits before requiring a zero offset. Raw diagnostic
failures are retained alongside the final logs.

This is component geometry and source/copy evidence. It does not certify a
visible Thread screenshot, physical trackpad/mouse behavior, app zoom, a live
scrollbar preference change, full native regression or hosted CI. In particular,
never-displayed synthetic wheel observations are not physical-device evidence.
Remote branch/PR queries failed to connect to GitHub; no remote gate is claimed.
There was no push or main integration; the central reviewer owns integration.

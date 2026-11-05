# Thread detail SwiftUI text migration

## Scope and decision

Agent Thread detail body text uses SwiftUI `Text` and
`.textSelection(.enabled)`. The user explicitly excludes cross-paragraph
selection and copying; no joined-selection coordinator is required. Local macOS
selection/copy remains in scope. Input editors, Moku notes/history, animation
implementation and other readers are outside this migration.

`ThreadConversation` opts in through `nativeMarkdownUsesSwiftUIText`, using its
existing Agent identity policy. The new environment value defaults to false:
`threadAgentDetail` itself defaults to true, so using it directly inside a shared
Markdown leaf would unintentionally migrate standalone notes and previews.
The existing cmark parser, media admission, table Grid, lists, code scrolling,
URL policy and document lifecycle remain shared. Adjacent styled spans form one
Text, retaining selection across bold/code/link runs in a paragraph. AppKit
remains only for platform actions, passive anchor geometry and the existing
first-paint host; this path creates no application-owned NSTextView.

Apple documents macOS range selection and Edit > Copy / keyboard copying for
[Text selection](https://developer.apple.com/documentation/swiftui/view/textselection(_:)).
This supports the requested per-paragraph implementation. A single flattened
Text would discard the existing table and nested block layout. TextEditor is an
editing control and is not the read-only rendering solution. TextRenderer adds
custom drawing, but does not supply a public joined-selection model; it is not
needed for the revised scope.

## Behavior and deliberate differences

- System selection and Copy operate within a Text. Cross-paragraph dragging,
  document-wide Command-A and selected multi-cell copy are not implemented.
- The existing Copy Markdown and Copy Code menus retain exact source strings.
  Copy Table exports the complete parsed table with tabs/newlines, including
  empty cells. It is not a selected-cell export. No new cross-paragraph copy
  action is added; the existing whole-document Copy Markdown remains available.
- URLs use SwiftUI's OpenURLAction and the existing document action/URL policy.
  Internal footnote links use passive block anchors in the same scroll views;
  a return targets the containing paragraph, not the exact reference glyph.
  Footnote references display bracketed superscript labels (`[1]`) so their
  visible hit target remains usable in selectable SwiftUI Text. A lone small
  digit failed both ordinary URL and footnote pointer fixtures on this SDK;
  very narrow user-authored link labels remain a known interaction risk.
  Temporary absolute-URL rewrites did not fix this and are not shipped.
- Loaded images are SwiftUI Image controls on their own line, with alt labels
  and actionable links. They no longer occupy inline TextKit attachments.
- Fonts, weight, foreground, strike, superscript and link styling carry over.
  Inter emphasis keeps the existing non-synthesized font policy. Code uses Menlo.
  Inline code has a rectangular attributed background without the old 5pt side
  padding/3pt rounded corners. SwiftUI owns line metrics; lineSpacing approximates
  the previous rhythm and is not pixel-equivalent fixed TextKit line height.
  Table sizing still uses existing text estimates, with intrinsic SwiftUI height.
  Code tab-stop geometry is system-owned; exact TextKit tab placement is not promised.
- The existing NativeThreadRevealRow gates first paint and joins the execution
  entrance. Text enters by block rather than individual TextKit lines. No timing,
  panel motion or cancellation code is changed. The parallel animation work must
  account for this renderer boundary when integrated.
- Native SwiftUI accessibility exposes text and links. Semantic heading traits
  and image labels remain. Full VoiceOver navigation, selection announcements,
  keyboard-only link activation and rich pasteboard fidelity need explicit
  system-level acceptance; rendering or AX text presence alone cannot certify them.
  SwiftUI may create its own NSTextView when selection activates. The migration
  removes application-owned text storage/layout, not OS implementation details.
- Streaming page estimates still use the shared metrics. Changed line metrics
  can shift perceived page fill; live follow and performance are not certified
  by the renderer tests.

## Verification

The production-component fixture is:

```sh
python3 tools/verification/reading-presentation/run.py --swiftui-markdown
```

It mounts actual readers, checks accessible text and absence of MarkdownTextView,
checks the unchanged default native reader, exercises system pointer selection /
Copy and link dispatch, resizes growing/shrinking content, navigates footnotes,
and copies production-parsed tables to the local pasteboard. The three
system-pointer methods have the mandatory `native/swiftui-markdown` owner and
required success markers; the remaining four methods participate in the ordinary
hosted Swift suite. Direct ordinary execution of selection and link clicks exited
zero without a terminal Swift Testing summary, so it is not accepted as a pass.

Initial replay caught the shared environment default leaking SwiftUI into
standalone readers; fixed by introducing the opt-in boundary above. The initial
failure is retained in `/tmp/swiftui-text-replay.log`. Double-click replay initially
omitted the first down/up pair; fixing the input sequence restored the expected
single-word Copy without product changes. The footnote fixture also exposed the
narrow-label limitation above; its original failures remain in
`/tmp/swiftui-text-footnote-details.log`. The bracketed label passes the same
navigation assertion. Clipboard-restoration test compilation required an explicit
main-actor closure signature. A graphical-lock conflict was deferred without
interrupting the other replay. Validation results are recorded below.

Remote rules queried on 2026-11-05 require a PR, strict `Complete coverage`, and
resolved review threads. Traditional branch protection returns 404; rulesets
remain authoritative. This task uses a detached managed worktree and returns a
commit for caller integration. No remote refs, rules or other worktrees are
modified, and no historical CI result certifies this commit.


### Local results on the delivered implementation

- Application and all test targets build successfully with
  `swift build --package-path app/macos --build-tests`.
- `make lint` passes, including architecture, formatting and Go vet.
- The ordinary Swift entry runs 15 affected tests (the four ordinary SwiftUI
  cases plus all eleven existing Markdown regression tests), with the registered
  native-method exclusion: all pass, no skips, complete summary (1.384s).
- `--swiftui-markdown`: all seven pass, including all three mandatory native
  markers (0.911s). AX content, system word selection/Copy, external link click,
  footnote forward/back navigation, resize/growth/shrink and table pasteboard
  bytes are exercised. AppKit-rendered fixture images were inspected; they are
  not a pixel-equivalence or WindowServer animation oracle.
- `--moku-execution-links`: all twelve tests across the two suites pass on the
  final renderer (51.266s), including all four Harnesses and complete reply
  occurrence counts through current/history transitions.
- `verify-ci-control.py` passes its ownership, actual launcher/deadline,
  receipt/marker, scope and cancellation checks. Real compiled discovery finds
  538 methods, with 524 ordinary and 14 native-owned; the three new identities
  are present. These are local checks, not a hosted Complete coverage result.

The integration check `--thread-send-feedback-native` remains **failed**:
`mountedProductionReadersHandOffAfterContentAdmission(width:mode:)` fails all
eight parameter cases at the existing line-396 assertion. After 150ms of travel,
`accessibilityFrame("conversation-sidecard")` is nil. The other three methods
pass. This attempt took 27.873s. A controlled run temporarily restored the two
modified rendering-entry files to HEAD (`7e1d36a`) in this worktree, then restored
the migration files in a `finally` block: the original native renderer reproduced
the same eight failures at the same assertion (27.619s). No animation implementation
or assertion was relaxed. This control isolates the rendering switch; it does
not certify the unexecuted remainder of handoff or make that check green.
Integration with the parallel animation work still needs that failure resolved.

Local logs are retained under `/tmp/`:
`swiftui-text-native-verified.log`, `swiftui-text-ordinary-verified.log`,
`swiftui-text-execution-links-final.log`, `swiftui-text-ci-control-final.log`,
`swiftui-text-final-lint-complete.log`, `swiftui-text-handoff.log`, and
`swiftui-text-handoff-native-control.log`. Fixture captures/receipts are under
`.scratch/reading-presentation/SwiftUIMarkdownReadingTests` and the corresponding
Moku/handoff suite directories. Per-attempt times above exclude build/launch and
do not describe total elapsed investigation time.

Not run: the complete local suite, final hosted CI, full VoiceOver acceptance,
image interaction/visual equivalence, rich pasteboard format equivalence,
performance measurements and the parallel animation demo. These omissions and
the narrow-link limitation above must not be presented as preserved/verified
behavior. Caller owns local-main integration and any subsequent remote gate.

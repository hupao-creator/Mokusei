# Agent detail: softer dark reading surfaces

## Reference and evidence

Research date: 2026-11-04.

- [Notion account settings & preferences](https://www.notion.com/help/account-settings)
  documents Light, Dark and system appearance. Its separate high-contrast setting
  increases text, icon and border contrast independently of appearance. It does
  not publish a normative color specification.
- [Notion's live login application](https://app.notion.com/login), reached from
  `https://www.notion.so/login`, served version `23.13.20261103.1827` in an
  isolated, unauthenticated browser context. Emulating the system dark preference
  set `notion-body dark notion-dark-theme` on the body. Reading the delivered
  stylesheet and computed body custom properties produced:

  | Role / CSS property | Observed dark value |
  | --- | --- |
  | Primary background / `--c-bacPri` | `#191919` |
  | Secondary / `--c-bacSec`, elevated / `--c-bacEle` | `#202020` |
  | Interaction / `--c-bacInt` | `#262626` |
  | Primary text / `--c-texPri` | `#f0efed` |
  | Secondary text / `--c-texSec` | `#ada9a3` |
  | Primary border / `--c-borPri` | `#383836` |
  | Secondary border / `--c-borSec` | `#2c2c2b` |
  | Strong border / `--c-borStr` | `#5f5e59` |

  These are directly inspected application CSS values, not sampled pixels or
  a claim about every Notion surface. The visible login form remained light
  through its own theme scope even with the dark preference. No authenticated
  workspace, dark editor screenshot or hover/focus interaction was verified.
  Notion can change these values without changing its public documentation.

The useful reference is the separation of canvas, secondary/elevated surfaces,
interaction fills, text and borders. Our previous canvas and secondary surface
already matched the observed Notion tokens. Copying them would not address the
reported excessive darkness. The following lighter charcoal values are Mokusei
design choices, not purported Notion colors.

## Implementation

| Shared thread role | Previous dark | New dark |
| --- | --- | --- |
| Canvas | `#191919` | `#232323` |
| Content surface | `#202020` | `#2b2b2a` |
| Soft / hover surface | `#202020` | `#2e2e2c` |
| Strong / composer surface | `#252525` | `#333331` |
| Secondary text | `#a19e98` | `#b3b0aa` |
| Faint text | `#96928c` | `#a39f99` |
| Border | `#383735` | `#4a4946` |
| Soft divider | `#2d2c2a` | `#3c3b39` |
| Accent fill | `#302a46` | `#3b3452` |
| Idle composer border | `#4b4d44` | `#5c5d54` |
| Focused composer border | `#64665c` | `#8c8d83` |

Primary text, strong text, purple accents, status colors, typography, geometry,
motion and control state logic retain their existing definitions. Every light
color component is retained. The asset catalog and literal pair names change
together, so SwiftUI, TextKit and the panel-travel shell resolve the same colors.
The shared `NativePalette.thread` also supplies other conversation/Markdown
readers and reading-panel chrome; those consumers inherit these dark tones.
Overview and Settings palette definitions and external Browser content are
unchanged. Composer borders retain their existing warm neutral family; running
borders still blend the accent and shared line color through the existing rule.

Static sRGB luminance calculations give body text contrast of 10.49:1 on the
canvas and 8.45:1 on the strongest neutral fill. Secondary text is 7.27:1 / 5.85:1,
and faint text is 5.97:1 / 4.81:1 respectively. Accent text on the accent fill is
5.52:1. The focused composer border is 3.77:1 against its fill. These calculations
cover opaque token pairs, not alpha-composited states, disabled controls, native
selection, all accessibility settings or a full accessibility conformance audit.

## Sprint verification and limits

The authorized scope is static review and optional compilation only: no new
tests, test execution, integration replay, hosted CI, push, PR or publication.
Work stays on the isolated detached worktree for caller-owned integration;
shared branches and other tasks' processes are untouched.

The read-only GitHub protection query failed with `error connecting to
api.github.com`; no remote gate status was obtained. This does not authorize
bypassing any gate during later integration.

Completed checks:

- Reviewed the source diff and all 11 adaptive asset replacements. All 85 literal
  palette pairs have matching JSON assets; all 11 replaced assets retain their
  exact light variant. Local documentation links and `git diff --check` pass.
- `xcrun swiftc -frontend -parse` passes for `NativePalette.swift` and
  `NativeComposerView.swift`. This is syntax checking, not module type checking.
- `xcrun actool … --platform macosx --minimum-deployment-target 26.0` successfully
  compiled the palette into `.build/detail-dark-assets/Assets.car` (exit 0).
  Xcode also logged unavailable CoreSimulator services and a denied simulator
  log-file write; the requested macOS asset compilation still produced its output.
- Attempted `swift build --target MokuseiPluginUI --jobs 2` with scratch, cache,
  configuration, security and module-cache paths isolated under this worktree's
  `.build/detail-dark-swift`. SwiftPM failed during dependency acquisition with
  missing repository-cache directories for WebRTC, cmark, Markdown, WebURL and
  swift-system (exit 1), before source compilation. No successful UI module or
  application build is claimed. No equivalent full build was retried.

No tests, replays, repository-wide lint or hosted CI were run. The repository's
`make lint` pre-commit hook is omitted only for this commit via command-scoped
`core.hooksPath=/dev/null`; no persistent hook configuration is changed.

No production-app screenshot or live interaction comparison was performed.
Static source/color review cannot establish perceived comfort on the user's
display, final native compositing, transition continuity or every interaction
state. Browser inspection above concerns the external reference only, not an
application replay.

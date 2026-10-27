# Moku demo drift audit

Baseline: `e70ca9877603d978d9910d73a4a1b32a614837dc`.
The supplied `pasted-image.png` (attachment
`58858831-f098-4047-b20c-6f4b4330275e`) shows the fixed glass-world fixture:
“Codex · Canvas material”, “Report · Glass review”, and a round Moku at bottom right.
These titles and the 95-point character mount identify
[`glass.swift`](../../glass.swift) as the source.

## Resolved drift

- The fixture used `MokuCharacterView`, while the production workspace mounts
  `NativeMokuDock`. It now mounts that same Dock with isolated in-memory state
  and draft services. Production owns the glass, eyes, idle size and bottom-center
  placement; no replacement brand drawing or production change was introduced.
- Capture metadata now names `NativeMokuDock` and records its measured frame.
  The replay requires the production idle size, centered position and stable
  Dock geometry across light/dark and glass-world on/off captures. The Dock's
  scene phase is inactive to freeze blinking; this is a static screenshot fixture.
- The independent Tag glass morph README still described a pending adoption
  decision even though the current native filter already implements morph.
  It now identifies the historical experiment and points to the production replay.
- The static Tag selection HTML uses a solid `accentSoft` selection and a 48%
  outline. Production `OverviewTagGlassSurface` instead uses clear glass tinted
  with accent at 22% (34% increased contrast). The HTML and its old measurements
  remain intact and are explicitly labeled as a historical visual proposal.
- Three earlier cloud/timeline demo builders reference the deleted
  `Sources/App/NativeContentHost.swift`; two also compile a subset of Host
  sources, and the card demos hand-build glass shells. The
  [demo inventory](../../../../../demos/README.md) documents their historical
  status and current replacement entry points. Restoring those separate shells
  would perpetuate drift, so their original sources are preserved.

## Intentionally retained

- Circular Thread emoji, completion marks and follow-up controls are real
  `HarnessThreadCard` controls, not Moku logos.
- `NativeMokuSettings` still uses `MokuCharacterView(usesResident: false)` for
  its coordinator illustration. Its geometry, materials and animation assets
  remain production dependencies; the circle is not globally obsolete.
- The packaged `app/macos/build/AppIcon.icns` is an application icon, not the
  fixture's Moku drawing. No evidence justifies replacing it or other brand assets.
- The existing switch-clipping screenshot and document under
  `reading-presentation/evidence` describe a specific historical before/after
  regression and remain unchanged. Supplied images are not rewritten.
- Existing Moku Talk, blink, note, voice-cloud and attachment replays already
  mount `NativeMokuDock`; Settings demos use the real settings page.
- Card models, plan, emoji, camera, fixed backdrop, cloud pause and material
  on/off values remain unchanged. The production Dock overlaps 16 points of the
  bottom cards' empty shell, without covering their text or controls. The shell
  inspector uses the longer exposed portion of those two strips, excluding the
  measured Dock plus a 12-point shadow margin; the other strips are unchanged. This patch
  does not change production shell material behavior or performance tooling.

## Validation and capture provenance

Generate fresh evidence from this worktree:

```sh
env -u MAKEFLAGS -u MAKEOVERRIDES -u MFLAGS make check ARGS=
python3 tools/verification/overview-input/run.py --glass-world .build/outdated-demo-cleanup/glass-world
```

The runner captures only its own isolated 1200×760-point WindowServer window.
It starts no runtime, reads no user profile, sends no model request and does not
install or restart the production app. The four PNGs and JSON reports retained
here belong to this refresh, not to the original attachment. They verify static
appearance and shell pixel differences, not optical frame pacing or physical input.

| Appearance | Glass world on | Glass world off |
| --- | --- | --- |
| Light | [PNG](light-on.png) | [PNG](light-off.png) |
| Dark | [PNG](dark-on.png) | [PNG](dark-off.png) |

Recorded 2026-10-25. Each original PNG is 2400×1520 pixels; the measured Dock
frame is `{{516, 680}, {168, 44}}` points in all four captures.
[Capture metadata](captures.json), [independent pixel inspection](inspection.json)
and [SHA-256 hashes](sha256.json) are retained alongside the images. Both themes
passed all five shell comparisons; the exterior backdrop mean difference was
zero. Visual review confirmed the round bottom-right Moku is gone and the
bottom-center production capsule leaves the card text, emoji and controls readable.

`make check` passed (architecture, formatting, vet/build, Swift build, concurrency
properties, module tests and 13 directory-tag cases). The initial sandboxed
attempt could not write the Go build cache; rerunning with authorized build-cache
access succeeded. The final fixture replay and independent PNG inspector both
passed after the Dock exclusion change. Full build/replay logs remain in
`.build/outdated-demo-cleanup/` in the implementing worktree. Diff whitespace
and changed Markdown links were checked. Independent source review found no
blocking issues; its geometry-check suggestion was incorporated before the final
capture replay. A final independent review also inspected all four PNGs and the
Dock-excluding pixel regions, with no blocking findings.

The historical cloud/timeline builders were not rebuilt or launched; their
removed source dependency was established by inspecting the scripts and current
tree. Physical input, Settings persistence and optical performance were not
tested because this change only updates a static fixture and documentation.
For integration with concurrent performance work, keep that work's measurement
code and incorporate the Dock mount/state, metadata and inspector exclusion
hunks in `glass.swift` / `inspect-glass.swift`; production material code is untouched.

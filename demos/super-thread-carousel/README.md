# Super Thread collection preview

```sh
python3 demos/super-thread-carousel/build.py --headless
open "$(cat .build/super-thread-carousel/app-path.txt)"
```

`--skip-build` reuses current Debug production objects. The builder packages an
independent ad-hoc app under `/private/tmp` and does not launch a GUI itself.
`--headless` exports fixture data before creating NSApplication; it mounts no
WebKit and produces no screenshots. `headless.json` contains fixture policy
outputs; `production-projection.json` uses real catalog, Overview model and
profile preferences in a temporary profile. Data export is not an assertion suite.

The visible app reuses production collection, card, cover and member panel views.
Its close records, time advancement, read sheets, tags and document bodies are
fixtures. The local fixture uses the Host's 16-cell budget and simulated close dates.
The production export exercises a qualified visit, profile reopen and observations
around the 24-hour boundary. The [Overview guide](../../app/macos/Sources/Host/Overview/README.md#viewed-application-collections)
owns the reading and grouping policy.

Cover playback, 360:308 logical viewport scaling and the 320×408pt grid footprint
come from production. Bottom navigation mounts only while actually hovered and
retires its native hit/AX children on exit; x/x remains the member-panel control.
The member panel scrolls real report-card fixtures, including coverless members.
To check the member panel, open the count on the collection card and scroll the
grid. Close stays in the upper-left corner while the cards move. In the 500×400
window at 2×, the compact column sits below Close. Click a visible member and
check that its report opens. Reopen the collection and check Close and Escape.
The preview's active/slow/time/window/zoom controls are local and cannot certify
system foreground lifecycle. It neither starts Runtime nor reads real sessions.

## Member archive replay

Use the visible preview with **9 篇成员** enabled. Open the page count and click
the archive icon on a visible member. The production card calls the fixture's
archive capability, and the new ordered members arrive through the production
panel update. Capture before, during and after removal. The outgoing card fades
and shrinks in place, then the grid closes the gap. Other members and **Close**
stay usable. Repeat with two different cards in quick succession. With the
expanded fixture off and only two grouped reports visible, archiving a member
closes the panel. **重置** restores the archived fixtures after closing.
The archive capability changes only in-memory fixtures. Live Runtime persistence,
associated Threads and system Accessibility input require product verification.

Requires the repository macOS/Xcode toolchain. This preview has no automated
correctness acceptance gate; it does not install or replace the production app.

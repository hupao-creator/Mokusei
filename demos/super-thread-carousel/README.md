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
fixtures. Production policy groups at least two eligible Super Threads after
strictly more than 300s since close; a foreground read over 120s clears retained
eligibility, while a short read can retain it. Carousel selection is not opening.
The [Overview guide](../../app/macos/Sources/Host/Overview/README.md#viewed-application-collections)
owns that policy and its fingerprint/close ownership.

Cover playback, 360:308 logical viewport scaling and the 414×522pt grid footprint
come from production. Bottom navigation mounts only while actually hovered and
retires its native hit/AX children on exit; x/x remains the member-panel control.
The member panel scrolls real report-card fixtures, including coverless members.
The preview's active/slow/time/window/zoom controls are local and cannot certify
system foreground lifecycle. It neither starts Runtime nor reads real sessions.

Requires the repository macOS/Xcode toolchain. This preview has no automated
correctness acceptance gate; it does not install or replace the production app.

# Settings tab visual study

```sh
python3 demos/settings-tabs/build.py --open
```

`--skip-build` reuses current Debug modules. The temporary app path is written to
`.build/settings-tabs/app-path.txt`. The study presents General, Moku, Tag and
Report tabs with in-memory state, local theme/material controls and sample model
catalogs. Moku map, branding and capability animation resources use production
modules; its surrounding fixture configuration panel is local to this demo.
The study's regular-glass outer shell is not the opaque production Settings shell.

Keyboard tab navigation, local theme/window controls and role mode choices
operate fixture state. No real installation, history deletion, native catalog,
Runtime persistence or account capability is established. Actual page behavior
belongs to [Settings](../../app/macos/Sources/Host/Settings/README.md) and the
[production-component preview](../settings-navigation/README.md).

Requires the repository macOS/Xcode toolchain. This preview has no automated
correctness acceptance gate; it does not install or replace the production app.

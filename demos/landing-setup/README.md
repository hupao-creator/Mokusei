# Landing setup preview

```sh
python3 demos/landing-setup/build.py --open
```

`--skip-build` reuses the current production Debug objects. The app path is
written to `.build/landing-setup/app-path.txt`. Discovery, installation, model
catalogs and saves use deterministic in-memory fixture data.

The preview presents discovery, Moku, Tag and Super Thread Agent configuration,
then contracts to the real Dock. It reuses the production Moku map, model/select
controls and capability animations. Host selection and target selection are
independent; inherited role configuration retains its separate independent
choice. The preview controls expose appearance, window sizes and simulated
installed/missing Harnesses. They do not establish authentication or model
availability. [Production onboarding](../../app/macos/Sources/Host/Onboarding/README.md)
owns actual readiness, persistence, off/inherit/independent modes and admission.

Requires the repository macOS/Xcode toolchain. This preview has no automated
correctness acceptance gate; it does not install or replace the production app.

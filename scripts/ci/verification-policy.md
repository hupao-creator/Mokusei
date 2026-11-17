# Verification policy

The project has removed all first-party automated test cases and test-only
helpers/fixtures. `make check` now runs formatting, architecture/import and static
registration checks, Go vet, all Go package builds and the Swift production build.
There are no unit, race/property, Swift test or correctness replay gates.
Do not interpret a build/static pass as runtime or visual correctness coverage.

[CI](README.md) retains these checks on Linux and macOS and keeps the aggregate
name `Complete coverage` for branch-rule compatibility. Before remote integration,
inspect the actual required checks and the final revision's status. A local run
cannot substitute for a hosted check required by branch protection. Local-only
artifact delivery does not trigger publication or remote runs.

For a change, prefer proportional non-test validation: source/manifest parsing,
formatting, affected production builds and static checks. Record actual results
and platform/toolchain limits; skipped or historical checks are not passes.
Pure documentation changes require diff and local-link review.

The retained [external benchmarks](../../tools/benchmarks/README.md) and
[performance tools](../../tools/verification/README.md) measure independent
performance questions. Calibration controls establish measurement capability;
they do not constitute product regression coverage or required merge gates.
Native XCTest hitch collection and portable conformance suites were removed.
Missing capture, permissions, signing or descendant accounting remains an explicit
measurement limitation. Historical evidence cannot certify the current revision.

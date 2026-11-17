# Continuous integration

[CI](../../.github/workflows/ci.yml) retains production builds and static checks.
No first-party test suite, integration assertion replay, test fixture producer,
native test inventory or test coverage report is configured at this source revision.

Linux runs Go formatting, architecture/import and static registration checks,
`go vet ./...` and `go build ./...`. macOS 26 arm64 builds all Go packages and the
Swift production products with warnings as errors and the Metal build plugin.
CGO/system SQLite and the exact Go toolchain in `go.mod` remain enabled.
SwiftPM and Go caches reuse compilation; current sources are always built.

`scope.py` classifies a conservative documentation-only diff from complete paths
and Git modes. Only root `AGENTS.md`, `README.md`, `CONTEXT.md`, the root Go/native/demo
READMEs and direct `.agents/*.md` / `scripts/ci/*.md` files are allowlisted,
with regular-file modes. Module READMEs, `docs/`, `design/`, packaged resources,
symlinks and unknown/mixed changes run production builds; dispatches do too.
The fast path validates diff whitespace, not Markdown links or factual accuracy.

The `Complete coverage` aggregate requires scope and Go plus the macOS build
for changes outside the documentation allowlist.
It certifies only these build/static checks and makes no test-coverage claim.
Actual remote protection rules still govern remote integration.

PR/main runs cancel obsolete runs only within their own event/ref. Dispatches
have separate groups. Other PRs are independent. The macOS job has a 60-minute
hang guard; this is not a whole-run acceptance deadline.

[Self-hosted deployment](self-hosted.md) retains isolated macOS routing and fork
PR boundaries. The optional [Overview performance workflow](../../.github/workflows/overview-performance.yml)
remains a manually dispatched measurement tool with fixed baseline/candidate
SHAs. It is separate from required build checks.

Locally use `make lint` and `make typecheck`, or their combined `make check`.
See the [verification policy](verification-policy.md) for limitations.

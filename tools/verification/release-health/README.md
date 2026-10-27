# Release runtime health gates

Run from the repository root on Apple Silicon macOS:

```sh
./scripts/go.sh run ./tools/verification/release-health -output /tmp/mokusei-health-run
# Also exercise the installed native Codex binary against a loopback model server:
./scripts/go.sh run ./tools/verification/release-health \
  -output /tmp/mokusei-health-native \
  -real-codex /absolute/path/to/native/codex
```

The output directory must not already exist. Each gate retains a private log;
`report.json` records the source revision (including a dirty marker), UTC start,
per-gate status, duration, error and relative log path. Results are written after
each gate, and failures do not suppress later gates. Any failed gate or interrupted
run exits nonzero. Skipped gates are explicit: a successful selected run does not
mean every release requirement passed. Run `make check` separately for static,
build, Swift and property-based checks.

`-only headless,moku,runtime` selects gates. `-timeout 10m` sets the deadline per
gate including compilation. `-cycles 5` controls headless restart cycles (minimum
two). Replays run sequentially with the race detector, an owned process group and
a bounded wait; timeout kills that group. Existing native adapters also own process
groups, so a forced timeout is a failed cleanup observation, not evidence that
all detached descendants stopped. Inspect the gate log and process inventory
before retrying a timed-out native gate.

## Evidence boundaries

- **headless** builds the actual runtime with `-race`, starts the production
  composition in a disposable profile and HOME, checks authenticated identity
  ten times per cycle, loads the durable Moku shell through the public command
  API and checks its identity across restarts, rejects unauthenticated health access, verifies repeated
  start preserves ownership, and checks stop/restart ownership and epoch changes. It also waits for each
  process to exit and checks the retained process output for race/panic diagnostics.
  Cleanup uses an independent deadline even after cancellation. Failed cleanup
  retains the profile and reports its location. No existing user profile is opened.
  The minimal environment has no model credentials or external CLI discovery;
  this is deliberately a service-lifecycle check, not proof of model readiness.
- **runtime / Moku / transport / concurrency / storage / applicationhost** use
  the existing production boundaries with scripted peers and real SQLite,
  including admission, cancellation, history recovery, settings, HTTP/NDJSON,
  scoped tools, receipts and shutdown. See the [replay index](../README.md).
- **harnesses and native-codex** cover protocol failures and native lifecycle.
  The Pi gate runs `-mode all` and therefore requires an installed Pi CLI;
  missing or incompatible Pi is a gate failure. `native-codex` is optional and
  explicitly skipped without a binary path. It
  uses the installed CLI with an isolated HOME and localhost-only provider,
  including truncated SSE recovery. It does not use a paid model account.
- **moku-system** (requires `-real-codex`) runs production composition with three
  directory scopes, real Moku child creation and terminal fanout to Report/Tag,
  foreign-scope rejection probes, model HTTP/SSE faults, public lifecycle actions
  and graceful restart with durable receipt replay. See the
  [combination runner](../moku-system/README.md) for generated cases and remaining
  scope. It is explicitly skipped when no native path is supplied.


Run `make check-stability` separately for the real daemon crash and 30-minute
single-process RSS/FD/native-process gate described in the
[Moku system guide](../moku-system/README.md#real-process-crashes-and-continuous-resource-gate).
The ordinary release runner does not implicitly run this long target.

These checks do not establish multi-hour/day memory/FD stability, production
provider availability, real-account authentication, model quality, or guaranteed
Moku provider-side effects. Moku terminal notifications now use a transactional
outbox with restart recovery and retries before native admission. Uncertain native
admission is retained and reported for explicit reconciliation rather than blindly
replayed; see the [Moku recovery procedure](../../../internal/services/moku/README.md#durable-completion-notifications). Runtime command locks now retire after the last holder/waiter, and cancellation
gates retire after durable session deletion and the last in-flight claim. Module
churn tests verify these lifetimes; they do not establish long-duration RSS bounds.

A release assessment should include the exact revision, `make check` result,
report and failing logs, installed CLI version, skipped checks, and unresolved
risks. Never commit credentials, discovery tokens, or user-profile contents as
evidence. One-off execution reports belong outside the source tree.

# Plugin module verification

`make check-modules` runs offline module tests with the Go race detector for all
backend plugins, plugin hosts, Runtime and Moku. It is part of `make check`. No account, model
server, external CLI or existing user profile is required by these module tests.

The application tests exercise Report persistence shape, scope and tag-source
contracts, hidden HTML exclusion, Tag scope-qualified Overview authority and
retired/unobserved selections, Git NUL-framed statistics and numeric bounds, and
shared background-tool lifetime and strict argument handling. Shared value tests
distinguish missing, null, optional and nullable fields.

Shared runner tests also exercise production settlement of native failure,
interruption and user-interaction states, timeout retry, exhausted attempts and
shutdown cancellation. They assert phase/attempt/duration diagnostics and native
error redaction while keeping durable retry and cancellation behavior intact.

The Artificial Analysis tests ensure unavailable, ambiguous, contradictory and
explicitly suppressed identities cannot acquire another release's evaluations.
The Harness module contract suites calls the real Codex, Claude, Pi and OpenCode
search adapters: only completed public content may be extracted; unfinished,
failed, interrupted, unknown-execution, tool and private fields stay excluded.
Existing native adapter tests cover additional settings, projections, voice and
cleanup contracts. OpenCode account telemetry tests constrain official endpoint
authority including scheme, credentials, port, query and encoded path boundaries.

Run one module with `./scripts/go.sh test -race ./internal/plugins/applications/report`
or one Harness contract with
`./scripts/go.sh test -race ./internal/plugins/harness/codex -run TestSearchTextPublicCompletedOnly`.
These fast module checks complement the [production-boundary replays](../../tools/verification/README.md)
and [release health runner](../../tools/verification/release-health/README.md).
They do not replace native protocol, SQLite integration, process lifecycle or
real-provider validation, and are not a claim of exhaustive branch coverage.

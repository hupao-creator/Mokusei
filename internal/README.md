# Go runtime modules

The Go module is `github.com/hupao-creator/Mokusei`, matching the source repository.
Mokusei remains the product and executable name.

The executable [mokusei-runtime](../cmd/mokusei-runtime/main.go) acquires a profile through the daemon and constructs the application through [composition/bootstrap.go](core/composition/bootstrap.go). Each composition owns its registrations, store, services and native process lifetimes.

| Module | Responsibility |
| --- | --- |
| [core/model](core/model/README.md) | Public commands, observations, records and validation |
| [core/plugin](core/plugin/README.md) | Harness and capability contracts |
| [core/runtime](core/runtime/README.md) | Admission, authoritative state, settings, lifecycle and projections |
| [core/store](core/store/README.md) | SQLite transactions, immutable snapshots and durable lifecycle work |
| [hosts/applicationhost](hosts/applicationhost/README.md) | Application registration, scoped operations and background participants |
| [hosts/contexthost](hosts/contexthost/README.md) | Moku-only context services |
| [plugins/harness](plugins/harness/README.md) | Integration guide and adapters for [Codex](plugins/harness/codex/README.md), [Claude](plugins/harness/claude/README.md), [Pi](plugins/harness/pi/README.md), [OpenCode](plugins/harness/opencode/README.md) |
| plugins/applications | [Report](plugins/applications/report/README.md), [Tag](plugins/applications/tag/README.md), built-in [Git](plugins/applications/git/README.md) |
| plugins/contexts | [Artificial Analysis](plugins/contexts/artificialanalysis/README.md) |
| services | [Moku](services/moku/README.md), [workspaces](services/workspaces/README.md), [search](services/threadsearch/README.md), [attachments](services/attachments/README.md) and tag normalization |
| platform | [Daemon/profile ownership](platform/daemon/README.md), [transport](platform/transport/README.md), process groups, environment and SQLite binding |
| tooling | Development/packaging, architecture checks and allowance-data maintenance |

The four Harnesses use externally installed native engines. Their account, model and credential configuration belongs to those engines. Pi and OpenCode embed small resources loaded by the external engine; the Mokusei application has no Node build or renderer process.

`internal/tooling/architecture/check.go` enforces the Go import graph across all source files and build tags, static registration and the allowed external JS resources. The generic store has no application-model dependency. Plugins do not import Runtime or construct their own Core authority. The Swift client consumes public projections over authenticated HTTP/NDJSON; it does not open the host database.

See [performance tools](../tools/verification/README.md) and [local checks](../.agents/linting.md). Module READMEs describe the implementation and its invariants; change history belongs in Git.

## Business evidence

Runtime and native application evidence belongs to business records: native
conversation history, Moku tool-operation transcripts, execution/tool results,
lifecycle events, durable command receipts and account usage ledgers. Recovery
notices still enter Moku's transcript; uncertain delivery is inspected through
`moku:deliveries` and reconciled through `moku:resolve-delivery`, as described in
[Moku](services/moku/README.md). User-visible failures, CLI/Probe responses and
`runtime/startup-error.json` remain their own output boundaries.

The runtime and app have no private service/tool journal, settings diagnostics
channel, layout/performance recorder or OSLog instrumentation. Business usage
telemetry and retained measurement artifacts are separate from these channels.
Development readiness uses a temporary one-shot PID receipt; native exit admits
the epoch-fenced cleanup helper through atexit with a separate 750ms deadline.
See [native lifecycle](../app/macos/README.md) and
[development launch](../app/macos/build/README.md#development-and-watching-main).

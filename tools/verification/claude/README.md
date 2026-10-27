# Claude native protocol replay

Run from the repository root:

```sh
go run -race ./tools/verification/claude
```

The executable launches itself as a deterministic Claude stream-json fixture.
Every Harness executable resolution points to this fixture, and every native
configuration directory points to a temporary directory created by the runner.
It does not launch the installed Claude CLI, read or write a real Claude profile,
or call a model/provider API. The runner removes its temporary configuration
and terminates the owned fixture process groups before exit.

The replay exercises the actual Go adapter and its actual OS subprocess pipes:

- Native initialization/catalog discovery and exact model/thinking controls.
- State-store-before-admission ordering, user replay acknowledgements, native
  message/result association, text fallback deduplication and usage collection.
- Public opaque question/option IDs and native answer reconstruction.
- Follow-up input within one execution, interrupt, background-task completion
  and host admission of a native background continuation.
- Native fork intent/history, isolated read and prompt completion.
- Usage/window ledger envelopes and deferred execution projections.
- Private discussion lifecycle with a temporary native fork.
- Unexpected root-process exit with a descendant retaining stdout/stderr,
  process-group cleanup, subsequent session recovery and session-ID fencing.
- Concurrent interrupt and close, plus repeated close.
- A real Go MCP subprocess, tool discovery, inactive dispatch rejection, JSON
  tool-result round trips and cancellation when its execution deactivates.

A success line is emitted only after all assertions pass. This is a protocol and
lifecycle integration replay. It does not establish compatibility with a
particular installed Claude release, SQLite persistence (this runner uses an
in-memory session store), model quality, network behavior, real
microphone/speaker behavior, or production performance. The discussion case uses
text input; audio capture/playback belongs to the native app and voice adapters.

The replay covers nested Harness tool schemas, overlapping branches and singleton
unions. They retain exactly-one validation without a root `oneOf`, which the
installed Claude client otherwise omits from its tools. These checks use the
protocol fixture and make no paid requests.

Native external-account configuration retains the CLI's declared model and
effort controls through thread resolution and execution capture. Unsupported
efforts and explicit `supportsEffort=false` still fail. Such a configuration
cannot borrow the native Claude subscription's quota.

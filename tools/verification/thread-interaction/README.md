# Production reading interaction replay

This runner launches the signed production Release macOS app and its bundled real
Runtime against an exclusively owned fixture profile. No replacement SwiftUI app,
mock Runtime, mouse simulation, model task or subprocess tool execution is used.
The fixture records completed Codex events through the production reducer and
validates the result with `DecodeState` before storing it.

```sh
python3 tools/verification/thread-interaction/run.py --steps 100
# Reuse an already built signed production bundle:
python3 tools/verification/thread-interaction/run.py \
  --app /absolute/path/Mokusei.app --seeds 41 929 20261024 --steps 120
```

The default run uses three seeds, each in a new profile, then replays the first
trace in another fresh profile using current mounted control handles. It checks
bundle ID, Release/production provenance and signature, fences socket responses to
the owned PID, records build provenance, launch metadata, application logs,
coverage, incremental JSONL and a summary under a new `/private/tmp/mokusei-reading-*`
directory. Cleanup terminates only its app PID and stops the bundled Runtime for
its isolated profile. Existing user data directories and installed app bundles
are not replaced.

The fixture has `interaction-a`, `interaction-b` and `interaction-c` with 1, 8 and
150 completed turns respectively. Each turn includes reasoning, three completed
tool activities, command output, Unicode, Markdown, a code block and a table.
The command/tool records are fixture data; no command is actually executed. The
150-turn case exercises the lazy sidebar index while only the current and selected
historical turn bodies are mounted. A fixed epoch keeps ordering repeatable.

To seed a profile independently, its parent must exist and the profile itself
must not exist:

```sh
./scripts/go.sh run ./tools/verification/thread-interaction /absolute/new/profile
```

The [reading control runner](../../native-interaction/thread_chaos.py) uses actual
mounted history, visibility, execution/tool/thinking disclosure and timeline
callbacks. It checks real row/execution load states, rendered turn counts, history
identity, window counts, Settings-return retention and stale-handle rejection.
Each absolute/relative scroll also asserts the final measured position, including
zero, 240 points, repeated 120-point steps and clamping at both document edges.
The [protocol guide](../../native-interaction/README.md#mounted-reading-controls)
describes the control roles and how to run/replay against an existing owned app.
This suite covers the Codex conversation reader. Composer/attachments, sidecards,
Git, links/media, other Harness readers and physical gesture fidelity require
separate fixtures and are not implied by successful navigation or this suite.

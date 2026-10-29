# Real macOS semantic interaction replay

```sh
python3 tools/verification/native-interaction/run.py
```

Builds and signs the **production Release `Mokusei.app`** through the normal
packaging command, then launches that unchanged app and its bundled Go runtime.
It verifies the production bundle identity, code signature and build provenance,
and records the bundle path/hashes in `application.json`. The production UI,
plugins, local persistence and normal runtime/environment discovery all execute.
The driver owns the launched PID and issues only navigation/search/filter actions.

To exercise an existing instrumented production release instead of rebuilding:

```sh
python3 tools/verification/native-interaction/run.py --app /absolute/path/Mokusei.app --steps 200
```

A new private data directory contains three threads seeded through the production
store. It does not use the user's daily profile. There is no substitute UI shell,
mock transport, ad-hoc test application or altered production binary.

Coverage includes protocol rejection, split/pipelined requests, frame bounds,
Overview → Settings → all sections → back, rejection of the removed archive
and plugin management sections, rejecting Settings from each thread while retaining
its reading visit and back action, search with empty results, filters,
stale target rejection, full smoke trace replay, and three seeds totaling 300
chaos actions with rapid transitions. Failures exit nonzero and retain the app
log, profile and incremental traces in the printed `/private/tmp/oa-ui-*` directory.
The driver terminates only its owned app and stops only its isolated runtime.
`--steps` controls actions per seed; the default is 100.

The existing Go settings launcher additionally drives the shared close action
against real drafts/daemon saves, including IME and validation rejection. Run
`./scripts/go.sh run -race ./tools/verification/settings`, the existing
[Overview input replay](../overview-input/README.md) when its boundary is affected.
Follow the repository verification policy; do not duplicate the full hosted suite locally.
See the [client/protocol guide](../../native-interaction/README.md) for other scripts
and agents.

## Settings internal chaos

```sh
python3 tools/verification/native-interaction/settings.py --steps 100
# Or reuse an instrumented signed production Release bundle:
python3 tools/verification/native-interaction/settings.py --app /absolute/Mokusei.app
```

This separate runner drives mounted form controls inside the production app.
Three seeds each start a fresh private profile and use normal native Harness
catalogs. Directed cases cover General preferences; Moku routing guidance and its enable toggle,
UTF-16 boundaries and native IME; real second-client CAS conflicts with both
retry/discard; Codex model/effort/tier dependencies; minimum dispatch targets;
application inheritance and disabled fields. Random actions choose the
current control handles/options. It checks persisted state through the real
Runtime public API and restarts both app and Runtime to verify durability.

It records signed bundle provenance, per-seed action/response/snapshot JSONL,
coverage counts, independent persistence snapshots, app logs and restart results
under the printed private evidence directory. Native catalog failures remain
visible as notices; a required directed case fails if its catalog cannot load.
No credentials are modified, CLI installed, model task sent or history deleted.
Save settlement allows 45 seconds for native catalog discovery (Pi has a
30-second deadline) and joined cleanup. Other UI actions retain their shorter
settlement bounds; runtime errors and unexpected CAS conflicts still fail.

Full system-prompt replacement and its reset controls were removed from the
product. The current driver follows the remaining routing controls and does not recreate
removed Settings fields. CAS cases edit routing guidance concurrently with an
independent dispatch-target reorder, checking both retry and discard.

For a deliberately scoped installed-Harness matrix, pass e.g.
`--harnesses codex claude pi`. The seeder writes activation and dispatch targets
only to each new isolated profile through the production store. It does not
change installed CLIs or accounts. Codex is required by the seeded conversations
and directed model cases; the Settings matrix requires at least two Harnesses
for its independent CAS target-order edit. The monkey restricts Harness buttons/selectors to that explicit matrix.
Evidence records the matrix; omitted Harnesses are not covered. The default still exercises all four Harnesses and still fails on
native configuration errors. All directed CAS/IME/Report cases, random steps and
restart assertions remain. Every seed initializes a real Codex execution profile through the public
settings-presentation boundary before ordinary edits; the separate Runtime concurrency replay covers editing before discovery
completes and still requires a real stale-save conflict.

Every application launch gets a new automation socket in its owned run directory.
SIGTERM may leave the previous socket name behind; the production bridge refuses
to unlink occupied paths. Restart checks keep the same data profile and require
the new app PID, then compare persisted settings and preferences. Launch identities
and endpoint paths are retained in the trace.

For a bounded `glass world` preference check without editing model settings:

```sh
python3 tools/verification/native-interaction/settings.py --glass-world-only --seeds 1 --steps 1
```

This uses the same exclusively owned production-app profile and mounted General
Toggle, compares the live `settings.glassWorld` snapshot with
`desktop-preferences.json`, alternates language/appearance writes, then restarts
the app and Runtime with the preference off and on. The Runtime settings object
must remain unchanged. Before taking that baseline, the runner waits up to 90 seconds for the isolated Runtime diagnostics to complete startup settings-discovery commands; their legitimate profile initialization is outside the preference comparison. The independent read oracle retries startup HTTP 503 responses for at most 45 seconds; control operations and persistence assertions are not retried or suppressed. It does not send model tasks. Offline save and failed-write
rollback are covered by the native Settings integration flow.

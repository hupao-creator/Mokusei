# Production Overview chaos

Run the current signed production Release application:

```sh
python3 tools/native-interaction/overview_chaos.py \
  --app /absolute/path/Mokusei.app --steps 200 --seeds 41001,41002,41003
```

The runner verifies the production bundle identifier, Release provenance and
signature. It launches that unchanged app with its bundled Runtime and normal
environment, an exclusively owned profile and the opt-in semantic socket. It
does not replace the UI or daemon, invoke a model, or modify the user's daily
profile. Three seeds each receive a fresh filesystem/profile, a deterministic
feature smoke sequence, then 200 mixed random actions.

`main.go` is a seed-only helper. It refuses an existing profile and writes ordinary
Codex records through the production store before launch. The fixture contains
real same-name directories, nested paths, Unicode/spaces, a symlink and an actual
Git repository/linked worktree. A separate `runtime-workspace/tmp-workspaces` path covers Inbox
suppression. Its archived record must never appear in Overview. Do not place the
ordinary fixture directory under a `mokusei-*` temporary root: the production
workspace policy intentionally classifies that root as Inbox.

The driver reads public Runtime `state:load` over its authenticated local HTTP
connection for independent membership and persistence checks. In particular, a
directory filter must include every eligible record in its canonical scope,
even when an alias cwd has a different display label. It also checks every
semantic child's exact scope, counts, layout cell occupancy, mounted identities,
camera limits, search restoration, actual directory menu callbacks and Moku
capsule navigation. See the [full feature matrix and limits](../../native-interaction/OVERVIEW.md).

Evidence is retained under the printed `/private/tmp/oa-overview-*` path:
production provenance, each seed's fixture, Runtime oracle snapshots, app log,
incremental `chaos.jsonl`, and `coverage.json`. The first unexpected failure stops
that run with its trace intact. Cleanup stops only the owned app PID and that
profile's bundled Runtime; fixture data remains for diagnosis. App launch and
stop are sequential within this runner. GUI acceptance scenes should also run
sequentially. Parallel scene testers need different profiles/sockets **and** must
keep each app window visible: occlusion can legitimately defer native camera
work. A responsive socket is not proof of a completed fit. The runner requires
the camera's real pending-work state to clear and its transform to reach the
production fit target; unexpected visibility blockers remain failures with their
reason in the trace.

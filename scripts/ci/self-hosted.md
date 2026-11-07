# Self-hosted CI deployment

Only macOS jobs migrate. The workflows support a staged migration; they do not
provision or register a runner. With no macOS routing variable set, all jobs retain their GitHub-hosted
platforms; Linux jobs always remain on `ubuntu-latest`. This avoids blocking the
required check while local capacity is absent.

## macOS routing and platform contract

| Repository variable, exactly `true` | Events routed locally | Required labels (all must match) |
| --- | --- | --- |
| `MOKUSEI_SELF_HOSTED_MACOS` | main pushes, dispatches, same-repository PRs | `self-hosted`, `macOS`, `ARM64`, `mokusei-macos-26-gui` |

Fork PRs retain `ubuntu-latest` / `macos-26`, even with the macOS variable enabled.
Linux Go checks, runtime/adapter replays,
scope and coverage aggregation retain their existing GitHub-hosted Linux jobs.
An absent/false variable retains the GitHub macOS platform. Once enabled,
a missing/offline matching runner queues the job: there is no timeout-based
fallback, platform substitution or passing skip. `macos-runner-preflight.py`
rejects an incompatible actual OS/CPU
before toolchain setup. Labels alone do not establish compatibility or trust.

macOS needs macOS **26 arm64**, Python >=3.11, Git, Bash, full Xcode with Swift
6.2+ and the Metal toolchain, the active Xcode selected, and sufficient disk space
for dependencies, Swift caches and two Release products. `setup-go` still honors
`go.mod`. Graphical jobs need an unlocked logged-in WindowServer session, real
backing/display delivery, functional Metal rendering and the capture/input
permissions required by the existing native assertions. SSH or a LaunchDaemon
alone does not supply this session. A macOS VM without working Metal/capture is
not equivalent. Validate a proposed guest instead of assuming GPU support.

Prepare motion/transparency settings and a display large enough for the four
foreground cards in the disposable image. The workflows change accessibility
preferences and permit automatic display-mode selection only on GitHub-owned
images. Self-hosted execution validates the existing display settings; it does
not rewrite the developer's preferences or resolution. The native environment
probe and all existing graphical assertions remain mandatory.

## Public repository trust boundary

This repository is public. GitHub [warns against using self-hosted runners for
public repositories](https://docs.github.com/en/actions/reference/security/secure-use#self-hosted-runners).
The fork-routing expressions are defense in depth, **not an access-control
boundary**: a PR can modify workflow YAML and request any repository runner label.
A label, read-only token, environment approval, or `author_association` check does
not sandbox code. Do not register this repository on a personal development
account or a persistent host containing credentials, signing keys or other work.

Before registration, supply an isolated, disposable machine for **each job**:

- No host home/source/keychain/SSH-agent mounts, personal accounts, host control
  sockets, signing credentials or provisioner/admin credentials inside the guest.
  Isolate the guest from the host and private LAN/services as well as other jobs.
  A container on the developer Mac is not this boundary.
- An outside-the-guest provisioner creates a fresh guest and registers a current,
  checksum-verified official runner using `--ephemeral`. Give it only the labels
  matching macOS 26 arm64 and the custom label above. Do not use
  `--replace`, `--disableupdate`, or copy a registered runner image/credentials.
- Run one listener in that guest; destroy the guest after its single job, including
  failure, cancellation, timeout and provisioner restart. `--ephemeral` removes
  registration after a job but does **not** wipe the machine, kill all descendants,
  or create a replacement. Retain diagnostics outside the guest before destruction.
- Replenish capacity for the entire run, including all native and extended jobs.
  One ephemeral registration can execute only one job, not a whole workflow. On each
  physical Mac, the provisioner must serialize guests/listeners across CI,
  extended CLI and Overview performance runs. The native suite/replays remain
  serial; the extended matrix admits one lane at a time on the self-hosted route
  and retains four-way parallelism on the existing GitHub route.
- Keep provisioning credentials outside the guest and logs. Fetch short-lived
  registration tokens only at registration, never into repository files or shell
  history; disable shell tracing. Do not print `.credentials*`, `.env`, tokens or
  keychain contents. Never bake a token into an image or workflow secret.
- Inspect fork approval policy and require review of **all external contributors**
  before registering capacity. This is additional review, not host isolation;
  approvals and an unmodified PR workflow cannot guarantee trusted execution.
  Do not use `pull_request_target` to check out and run PR code.

For long-lived isolated hardware, restore a verified clean image after every job
before making it eligible again. A dedicated user plus checkout cleanup is not
machine restoration. If the isolation/GUI requirements cannot be met, retain the
GitHub platform rather than expose the developer machine. See GitHub's
[runner setup](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners)
and [ephemeral runner guidance](https://docs.github.com/en/actions/reference/runners/self-hosted-runners#ephemeral-runners-for-autoscaling).

## Deployment and acceptance

1. Use the repository's `hupao-creator` gh identity. Inspect inventory **before**
   registration; inspect existing `.runner` metadata without reading credentials.
   Reuse a healthy matching deployment; do not register duplicates, replace a
   busy runner, cancel other tasks or change main protection rules.

   ```sh
   gh api user --jq .login
   gh api repos/hupao-creator/Mokusei/actions/runners \
     --jq '{total_count,runners:[.runners[]|{id,name,os,status,busy,labels:[.labels[].name]}]}'
   gh api repos/hupao-creator/Mokusei/actions/permissions/fork-pr-contributor-approval
   gh api repos/hupao-creator/Mokusei/rules/branches/main
   gh run list -R hupao-creator/Mokusei --limit 10
   ```

2. Build the isolated images/provisioner above. Download the official runner for
   **osx-arm64**, verify its published checksum, and register a
   uniquely named ephemeral guest using a token supplied securely by the external
   provisioner. Keep default OS/CPU labels; add only the appropriate custom label.
   Inside a clean guest checkout run:

   ```sh
   python3 scripts/ci/macos-runner-preflight.py
   # macOS GUI session, with its image's display policy already prepared:
   xcrun swift scripts/ci/native-environment.swift
   ```

   Check the Actions inventory reports an online runner with every matching label.
   Maintain **one** active native listener per physical Mac. Do not install a
   persistent developer-account service to work around a missing GUI guest.

3. Integrate the migration commit through the caller's normal review process.
   Enable macOS routing only after its provisioner, cleanup and replacement path
   work. This non-secret repository variable affects new jobs; it does not move
   running jobs. Record its existing value before changing it.

   ```sh
   gh variable set MOKUSEI_SELF_HOSTED_MACOS --body true -R hupao-creator/Mokusei
   ```

4. On the final integrated revision, run ordinary `CI` and confirm every job's
   actual runner identity, OS/CPU, complete native evidence and **Complete
   coverage**. Exercise a documentation diff, a same-repository PR and a fork PR
   to observe routing. Dispatch the separate `Native CLI` workflow for the four pinned CLI/system
   lanes; its distinct aggregate does not replace ordinary coverage. Dispatch
   Overview performance with reviewed full baseline/candidate SHAs, checking both
   AB/BA evidence and foreground validity. Historical flaky-case findings are
   recorded in [the review](flaky-review.md); remaining assertions and coverage
   owners stay mandatory. Confirm guest destruction, replacement and absence of
   host access even after cancellation. Inspect a failure before
   retrying only failed jobs at the same commit.

5. Preserve logs, attempt and commit identities; follow [verification-policy.md](verification-policy.md).
   main still requires strict current-head `Complete coverage` from GitHub Actions.
   Local syntax/preflight checks and another revision's CI cannot certify rollout.

## Rollback

Set the affected variable to `false` (or restore its recorded prior value). New
runs return to their existing GitHub platform; an already queued job does not
change routes. Coordinate any replacement run with other work, and drain only
this deployment's guests after current work finishes. Remove only registrations
created by this deployment; never delete an unrelated runner or rewrite branch
protection. Keep failed evidence. A rollback does not turn missing checks green.

## Inspection on 2026-11-02

The managed worktree started at `aff55f7f3104d8657a051f02dc170d026169d908`.
Authenticated GitHub API inspection found a public repository, admin access,
**zero** repository runners, no macOS routing variable, no environments, default
read-only workflow permissions, and `first_time_contributors` fork approval.
The active main rules require a PR, resolved discussions, strict freshness and
`Complete coverage` from the GitHub Actions integration (15368). Other CI runs
were already active; they were not cancelled or modified.

The local host is macOS 26.5.1 arm64 with Xcode 26.5 and a working Metal compiler.
No runner metadata was found in common install locations (home/Desktop/Developer/
opt and `/opt`, bounded scan), no Actions LaunchAgent or listener/worker process
was observed, and the checked Parallels directory was empty. No Docker, Colima,
Tart, QEMU or Parallels CLI was available on the inspected paths. This is not an
exhaustive inventory of all disks. The host has no demonstrated isolated macOS
GUI/Metal guest. No local Linux capacity is required for this migration.
Toolchain availability alone does not certify graphical tests or make the
personal account a safe CI host.

A read-only graphical probe inside the sandbox saw no session or Metal device.
Outside the sandbox it observed an active session, two Retina displays, an
Apple M1 Pro Metal device and disabled Reduce Motion/Transparency. Screen-capture
preflight was false for that inspecting process; no permission prompt was
requested and this does not establish permission for a future runner identity.
No actual capture/native suite was certified.

Sandboxed GitHub access failed; an approved network escalation allowed read-only
API inspection. Registration-token creation was not attempted: permission/network
were not the blocker; safe execution capacity was. No runner, service, token,
variable, approval policy or branch rule was created or changed. The migration
remains **prepared but not enabled** until the isolation and platform prerequisites
above are supplied and the final revision passes actual Actions validation.

## Verification of the prepared change

Local checks covered actual macOS platform admission, controlled wrong-OS/CPU/OS-
generation rejection, 81 evaluations of the three workflow routing expressions,
embedded Bash syntax, Python syntax, local documentation links, and the existing
CI scope/native-ownership/deadline control verifier. All four Linux job definitions
were compared as parsed YAML against the starting revision and are unchanged.
The architecture/static-registration/no-Node check passed.

Official actionlint 1.7.12 was downloaded to `/tmp` and checksum-verified. It
reported only the pre-existing `concurrency.queue: max` diagnostic, also reproduced
on the unmodified workflow. With that one baseline diagnostic excluded, both
workflows validated; shell blocks were additionally checked with `bash -n`.
No full native/build/replay run or current-revision Actions result is claimed.
Those remain deployment acceptance, including actual capture permissions and
Metal pixels in the runner's own session.

## Current restoration status

The optional routing contract above predates the local-verification migration.
No runner was registered and the routing repository variable is unset; restoring
these workflows therefore keeps execution on GitHub-hosted macOS by default.
This restoration does not install/start a runner or modify repository approval
or protection policy.

# Self-hosted CI deployment

The workflows support optional macOS routing; they do not provision runners.
Without `MOKUSEI_SELF_HOSTED_MACOS=true`, builds use `macos-26`. With it enabled,
main pushes, manual dispatches and same-repository PRs select all four labels:
`self-hosted`, `macOS`, `ARM64`, `mokusei-macos-26-gui`.
Fork PRs retain GitHub-hosted runners. Linux scope, Go/static and aggregation jobs
always use `ubuntu-latest`. Offline matching capacity queues work without an
implicit fallback or passing skip.

The build platform needs macOS 26 arm64, Python >=3.11, Git, Bash, full Xcode with
Swift 6.2+, the active Xcode selected and the Metal toolchain. `setup-go` honors the
exact toolchain in `go.mod`. `macos-runner-preflight.py` validates OS/architecture.
Routine CI runs generated geometry properties after the Swift build. Mounted
Overview state and real-native system properties are opt-in, outside this workflow.

The manually dispatched Overview performance experiment still requires an
unlocked graphical session, functional Metal/capture, existing input permissions,
and sufficient display size. Provision its motion/transparency settings in the
isolated image. The workflow does not rewrite a self-hosted account's preferences
or resolution. Ordinary production builds do not require WindowServer assertions.

Use a fresh single-job isolated guest for each untrusted job. Keep jobs serial
on each physical Mac, replenish guests between jobs, and never expose a developer
checkout, user data or signing credentials to untrusted PR code. Labels and
workflow routing do not establish isolation. Retain job logs and measurement
artifacts, and verify the actual current-revision required checks before remote
integration. This task does not provision capacity or change remote branch rules.

## Public repository trust boundary

For public repositories, GitHub [warns against using self-hosted runners for
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
- Replenish capacity for every job selected by the current workflows.
  One ephemeral registration can execute only one job, not a whole workflow. On each
  physical Mac, the provisioner serializes guests/listeners across production
  builds and Overview performance runs. No extended CLI matrix or native
  assertion suite is configured in the current workflow.
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

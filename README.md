# Mokusei

Mokusei (木犀) is a native workspace for coordinating AI agents. Moku is its coordinating assistant.

Source repository and Go module: [`github.com/hupao-creator/Mokusei`](https://github.com/hupao-creator/Mokusei).

Mokusei uses a Go background service and a native SwiftUI/AppKit macOS application. Development, builds and packaging do not require Node. External Harnesses manage their own runtimes; Pi and OpenCode retain small JavaScript resources executed inside those external tools.

Repository layout:

```text
app/
  macos/             Swift package and macOS application
    Sources/
      App/             macOS application entry
      Composition/     Shared static plugin registration
      Core/            Runtime client and shared protocol models
      Host/            Native host UI, navigation and feature surfaces
      Shared/          Plugin API and shared plugin UI
      Plugins/         Harnesses, Applications and Sidecards
      Tools/           Protocol and host service probes
    Plugins/           Swift build plugins
    build/             Signing and packaging assets
cmd/                 Go executable entry points
internal/
  core/              Composition, models, plugin API, runtime and state store
  hosts/             Application and Context plugin hosts
  plugins/           Harnesses, applications and contexts
  services/          Moku, attachments, search, tags and workspaces
  platform/          Daemon, transport, processes and SQLite
  tooling/           Development, architecture and maintenance
tools/verification/  Independent performance measurements and native packaging
demos/               Native interaction prototypes
```

See [native build and packaging](app/macos/build/README.md) for Mac client development, signing and verification.
The [demo inventory](demos/README.md) distinguishes production-component previews from independent visual experiments.

Directory groups organize existing modules. Swift target names and dependencies
are declared in `app/macos/Package.swift`; Go package dependencies are checked by
`internal/tooling/architecture`.

Requirements: Apple Silicon, macOS 26 or later, Xcode with the macOS 26 SDK and command-line tools, and Git. Signed development, packaging and installation also require an Apple Development identity with its private key; there is no ad-hoc signing fallback. `scripts/go.sh` locates or downloads the pinned Go toolchain and verifies the official archive checksum. SQLite uses the system C library through cgo.

```sh
git clone https://github.com/hupao-creator/Mokusei.git
cd Mokusei
make runtime                  # .build/go/mokusei-runtime
make build                    # Go service and Swift application
make dev                      # signed development application
make dev ARGS=--fresh         # launch with a clean development data directory
make check                    # static checks and Go/Swift production builds
make install-hooks            # repository-local pre-commit hook
make pack                     # signed production bundle
make dist                     # signed production bundle and zip
make install                  # build/sign and install to ~/Applications/Mokusei.app
make open                     # open the installed application
make smoke ARGS='--app "/absolute/path/to/Mokusei.app"'
```

Cloning requires whatever access is configured for the repository. `make build` checks compilation without installing an app. `make install` builds and signs a production bundle, refuses to replace a running installation, and requires the signing identity described in the [packaging guide](app/macos/build/README.md). No prebuilt or notarized release is provided by this source delivery.

The service owns its profile independently of the client connection. A disconnected client does not cancel accepted work. Explicitly quitting the native application requests a coordinated runtime shutdown. Manage an isolated profile directly:

```sh
.build/go/mokusei-runtime start --data-dir /absolute/profile
.build/go/mokusei-runtime status --data-dir /absolute/profile
.build/go/mokusei-runtime stop --data-dir /absolute/profile
```

Use `./scripts/go.sh run ./cmd/mokusei-dev --help` for development and installation commands. Native OpenCode allowance-data maintenance is in `cmd/mokusei-maintain`.

[Performance tools](tools/verification/README.md) measure isolated Runtime and native presentation paths. They do not provide correctness replay coverage. [Plugin contracts](internal/core/plugin/README.md) describe Go extensions. [Runtime module documentation](internal/README.md) and [native module documentation](app/macos/README.md) map the current implementation. [Contributor checks](.agents/linting.md) describe the local validation workflow. [Continuous integration](scripts/ci/README.md) defines Linux/macOS build and static checks, including their documentation scope.

Mermaid fences display as source code. The built-in [Git application](internal/plugins/applications/git/README.md) supplies read-only worktree facts on task cards and on-demand file/diff query APIs. Managed Git worktrees are owned by the [workspace service](internal/services/workspaces/README.md).

Current behavior, constraints, limits and runnable commands live with their owning
modules. The [fact index](docs/facts.md) connects those documents to implementation
and validation boundaries; the [coverage map](docs/coverage.md) lists every
first-party document and its evidence limits. Documentation describes implemented
state. Git retains design and change history. Measurement reports retain source,
collector and artifact identities so results remain attributable.

Before/after measurements require the named baseline revision to be available
locally. A report for another revision does not certify the current build.

## License

Mokusei is licensed under the [Apache License 2.0](LICENSE). Copyright 2026 hupao-creator.

Third-party materials retain their existing licenses and attribution notices, including [agent skills](.agents/skills/LICENSE), [fonts and icons](app/macos/Sources/Shared/PluginUI/Resources/), and [Unicode data](internal/services/taglabel/UNICODE-LICENSE.txt).

At this source revision, no first-party automated test suites or Swift test
targets are configured. Build/static validation is described in the
[contributor guide](.agents/linting.md). Project behavioral verification uses
PBT for Moku runtime, e2e for interactions and performance benchmarks for user
experience; this ownership does not imply those gates are implemented here.

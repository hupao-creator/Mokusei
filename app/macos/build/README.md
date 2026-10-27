# Native macOS build and packaging

For script-driven navigation and chaos testing, launch with `--automation-socket`
and an explicit `--data-dir`; see the [interaction guide](../../../tools/native-interaction/README.md).

Mokusei is a native Apple Silicon application for macOS 26 and later.
Its SwiftUI/AppKit interface launches a packaged Go runtime. Mokusei's build,
packaging and development commands use Go and Xcode. External
harnesses manage their own dependencies, which may include Node.

## Commands

Run from the repository root:

```sh
make dev          # build, sign and open the isolated development application
make fast         # incremental Go/Swift build into a new development generation
make watch-main   # rebuild each clean local main commit
make build        # build Go runtime and release Swift application
make pack         # sign app/macos/dist/Mokusei.app
make dist         # also publish Mokusei.app.zip
make smoke        # validate the packaged production app with an isolated profile
make install      # install to ~/Applications/Mokusei.app
make open         # open the installed application
```

Each target invokes `./scripts/go.sh run ./cmd/mokusei-dev`. The wrapper
downloads the pinned official Go archive into
`~/Library/Caches/Mokusei/toolchains`, verifies its SHA-256, and atomically
installs it there; it needs no preinstalled Go and does not change your global Go
or shell configuration. Use `ARGS` to pass options,
for example `make fast ARGS='--no-open'`, or invoke `./scripts/go.sh run ./cmd/mokusei-dev` directly.
`./scripts/go.sh run ./cmd/mokusei-dev help` lists commands. `GO=/path/to/go make build`
selects the toolchain for Make; `MOKUSEI_GO` selects a Go executable for child
builds. The version in `go.mod` is the required Go toolchain; `VERSION` supplies
the application version.

Building requires Apple Silicon and Xcode's macOS 26 SDK; `scripts/go.sh` provides
the pinned Go toolchain. Packaging also
requires one valid Apple Development identity with its private key. `CSC_NAME`
selects an exact certificate name or SHA-1; `CSC_KEYCHAIN` selects its keychain.
There is no ad-hoc signing fallback. List available identities with
`security find-identity -v -p codesigning`; the private key must be accessible
in the selected keychain. Stable signing preserves the designated requirement
used by privacy permissions across rebuilds.

Development uses `com.mokusei.native.dev`, `Mokusei Native Dev.app`
and the `Mokusei Native Dev` profile. Production uses `com.mokusei.desktop`,
`Mokusei.app` and the canonical `Mokusei` profile. The Go runtime
binary is built at `.build/go/mokusei-runtime`. A raw Swift executable can use
`--runtime /absolute/path/to/mokusei-runtime --data-dir /isolated/profile`.

Build and package do not install applications. `install` refuses to replace a
running installed app, verifies a private staged copy, and restores the previous
installation if publication fails. Specify `--destination` only when intending
to install at that location. These tools never quit the user's production app.

## Development and watching main

Go and Swift retain their compiler caches. `fast` always packages and verifies
a new Debug generation under `app/macos/dist/fast/`; there is no Node dependency
tree to redeploy. Existing processes keep their original executable and resource
paths. Generations retain the development bundle identity, signing team,
entitlements and default profile. Multiple development instances share that
profile. `--no-open` prepares a generation without launching it; `--rebuild` is
accepted, and all generations already perform complete packaging verification.
Old generations are retained while applications may still reference them. After
closing development apps, remove `app/macos/dist/fast/` to reclaim disk space.

`dev --fresh` and `fast --fresh` rotate the development profile to
`<profile>.previous` before opening the application. Native startup and rotation
share a nonblocking admission lock. A native client acquires a shared canonical
profile lease before reading preferences or drafts and retains it until process
exit. Rotation holds admission and exclusive client leases for both the current
profile and previous backup, then acquires the existing runtime ownership
guards. It refuses a live client or runtime owner of either profile, including
another checkout or a headless daemon using the backup. A late native startup
is rejected before reading retained state while rotation holds admission.
Ownership rejection preserves both directories. If the backup is missing,
rotation uses rename without deleting a destination that a runtime launcher may
create concurrently. Lease files live outside the profile directories and are
never removed or replaced when profiles move.
`--no-open` does not rotate data.

A runtime guard rejection identifies the blocked canonical profile and ownership
port and prints a cooperative stop command for that profile, including when the
previous backup is owned. Quit native clients first. If stop reports
`SHUTDOWN_FAILED`, inspect the selected profile's `runtime/process.log`; the
daemon records the error and exits after cleanup, allowing the next launch. The development tool does not force termination or discard profile data.
Swift targets explicitly exclude their module READMEs from build inputs.

Rotation retains a native process scan as an additional guard. The scan follows
kernel executable paths and argument
boundaries, including older `fast` generations, other checkouts, explicit
`--data-dir` aliases and the runtime-exit helper. Bundled default profiles use
Foundation's account home (or `CFFIXED_USER_HOME`) and `MokuseiDataDirectoryName`,
rather than shell `HOME`; a live candidate whose
profile cannot be inspected causes rotation to fail closed. The scan runs
again under all locks before any directory is removed or renamed. The optional
`FreshDevelopmentDataWithObserver` callback observes that final boundary while
the locks remain held; returning an error leaves both profiles unchanged.
The normal CLI does not install an observer. See the [profile lease contract](../../../internal/platform/profile/README.md).

Finite build and packaging commands own their process groups. Cancellation and
leader exit run descendant cleanup while holding the build lease. An artifact
is published only after cleanup succeeds. These commands
retain normal stdin and live output. This ownership does not include programs
that deliberately detach into another process group or session.

`watch-main` locates the worktree containing local `main` and polls every second.
It waits for a clean checkout, compiles and directly invokes that checkout's Go development tool, and
checks the commit and cleanliness again after the build. Failed commits retry
at most three times, with 30 seconds between attempts. It never fetches, pulls,
resets or changes main. Commits arriving during a build are picked up next.
Cancellation waits for the invoked tool to finish its own compiler cleanup and
release its build lease before the watcher returns.

Development launches use LaunchServices and wait for native window readiness
plus a three-second survival period. Startup times out after 30 seconds. Logs
are private files under `~/Library/Logs/Mokusei Native Dev/launch-*`, outside
TCC-protected checkout locations such as Desktop. Stopping the temporary
LaunchServices observer leaves the application running. Runtime connection
continues asynchronously; these readiness checks do not prove harness behavior.
The tools do not reset or grant privacy consent.

## Package contents

```text
Contents/MacOS/Mokusei
Contents/MacOS/mokusei-runtime
Contents/Frameworks/LiveKitWebRTC.framework
Contents/Resources/MokuseiNative_MokuseiPluginUI.bundle
Contents/Resources/AppIcon.icns
Contents/Resources/build-provenance.json
Contents/Resources/licenses/
```

Mermaid fences display source code. The built-in [Git reader](../Sources/Host/Git/README.md) is part of the active native target.
There is no content-renderer subprocess. WKWebView remains available for browser
and authored HTML document content.

The application icon is generated entirely from geometry defined in this
repository; see
[its source, regeneration command and historical provenance limit](SOURCES.md).

## Web content networking

Development and production bundles use the same generated ATS policy in
[`bundle.go`](../../../internal/tooling/devtool/bundle.go).
`NSAllowsLocalNetworking` permits local networking, including the native
client's loopback runtime connection. `NSAllowsArbitraryLoadsInWebContent` is
retained for the [Browser sidecard](../Sources/Plugins/Sidecards/README.md),
which accepts user-selected HTTP and HTTPS destinations without a fixed domain
list. Authored HTML initially loads through the in-memory `mokusei-html` scheme,
but its navigation, frames and web resources may also use remote HTTP(S).
The native SwiftUI/AppKit interface itself does not need this exception.

The web-content exception applies to every WKWebView in the application,
including authored HTML and future WebViews. It permits cleartext web traffic
and relaxes ATS transport requirements for web content; it is not a
confidentiality guarantee. It does not disable ATS for URLSession. See
[Apple's definition](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloadsinwebcontent).
Removing it, or limiting it to fixed domains, would change the existing browsing
contract. Local-network permission alone does not preserve arbitrary public
HTTP destinations. The loopback browser tests and SwiftPM builds do not prove
public HTTP behavior under the packaged app's plist; any future restriction
requires an actual packaged-app navigation check with a controlled nonlocal
HTTP destination.

## Resource validation

The packaging tool preserves Swift resource bundles, validates fonts and icon
geometry, checks architecture and dynamic dependencies, and removes nonportable
SwiftPM rpaths. WebRTC is copied with its framework symlinks and thinned to arm64.
The framework, Go runtime and outer app are signed in dependency order with the
same Apple Development team. Only the app receives the microphone entitlement;
Go needs no JIT entitlement. Publication uses the existing locked atomic C
publisher. Archives are created from the verified private staging tree.

## Validation

Packaging verifies signatures, resources and the embedded WebRTC load/SSL path.
`smoke` additionally verifies final product metadata, portable binary linkage,
privacy entitlement, absence of old Node artifacts, and isolated runtime
start/status/stop identity. Its temporary profile and derived workspace are
removed only after a successful smoke and confirmed shutdown; failures retain
the profile for diagnosis and report its location. Smoke never opens a GUI,
requests microphone consent,
or captures physical audio.

`make check` runs Go formatting/static checks, Go/Swift builds and the required
functional regression checks.
The [devtool replay](../../../tools/verification/devtools/README.md) additionally
checks profile rotation, active compiler cancellation and nested watcher cleanup
with isolated process fixtures.

This is a locally signed direct-distribution build. Notarization, public release,
automatic updates and App Store submission require a separate release workflow.

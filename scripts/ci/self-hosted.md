# Superseded runner preparation record

The user replaced the self-hosted runner plan with [local macOS CI using
gh-signoff](local-macos.md). **Do not register or start a runner for this task.**
No runner was ever registered, no listener/service was started, and no self-hosted
routing variable was enabled. The downloaded packages are inactive software,
not a functioning CI deployment. Linux execution was never migrated.

## Actual local preparation

The private install root is:

```text
/Users/felixwang/Library/Application Support/Mokusei/CI
```

| Installed package | Relative executable | Verified official archive SHA-256 |
| --- | --- | --- |
| Actions runner 2.338.2, osx-arm64 | `runner-2.338.2/bin/Runner.Listener` | `25a065af409ffa317ab4d5a3b614dd15fc9c40f2172bc1b35a1b1258e919a388` |
| Tart 2.41.1 | `tools/tart-2.41.1/tart.app/Contents/MacOS/tart` | `e680a734febccfce7d4e910c1f7f13fc3b00f19a181c945e2d746de3214c32c2` |
| Softnet 0.25.0 | `tools/softnet-0.25.0/softnet` | `5a2e8ef779f0a2169b88d273ee806c0d64321ec7714c0dc99bf217523ae9b008` |

All version commands worked. Archives remain in `downloads/`. Install directories
are private to the user. Nothing was copied into another project checkout.

## Attempts and exact limitations

- Sandboxed `gh api` returned `error connecting to api.github.com`; an approved
  network escalation succeeded. The account is `hupao-creator`, with repository
  admin access. The repository is public and owned by a User, not an organization.
- The registration-token endpoint succeeded. Its token stayed in process memory
  and was discarded without printing or saving it. This was a permission test,
  not a registration. Runner inventory before/after remained zero.
- The server-side fork policy was changed from `first_time_contributors` to
  `all_external_contributors` and read back successfully. This protects execution
  approval on GitHub, but is not a sandbox for approved source on a personal Mac.
  Existing main branch protections were not changed.
- The GitHub package-version listing returned HTTP 403:
  `You need at least read:packages scope to get a package's versions.` Public OCI
  pulls did not require that permission: Tart successfully read the image manifest.
- Python urllib's default certificate store returned
  `[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: unable to get local issuer certificate`.
  Verified system TLS via `/usr/bin/curl` and Tart worked; TLS verification was
  never disabled. Public image manifests showed 26.4 GB compressed for the base
  image and 69.3 GB for `ghcr.io/cirruslabs/macos-tahoe-xcode:26.5`.
- The actual Tart clone used a separate `TART_HOME` under this private root,
  `TART_NO_AUTO_PRUNE=1`, a unique VM name and two download streams. It reached
  `pulling disk (69.3 GB compressed)... 0%`. After finding the privilege blocker,
  only this task's exact pull process was interrupted; its final
  `Compression.FilterError error 1` followed that interruption and is not evidence
  of a defective upstream image. Partial cache data may remain under `tart/`.
  No VM was booted and no host folder/clipboard was shared with a guest.
- Both `sudo -n true` and `sudo -n .../softnet --help` returned
  `sudo: a password is required`. Softnet's official implementation needs root
  initialization through a root-owned SUID helper or configured sudo. No root
  helper, SUID bit or passwordless sudo policy was installed. Its binary was
  unsigned (`code object is not signed at all`); authenticity was checked against
  the official release archive digest. This path was abandoned when the user
  selected gh-signoff; no administrator action is needed for the new plan.
- Outside the sandbox the host exposed an active graphical session, two Retina
  displays, Apple M1 Pro Metal and enabled motion/transparency. Capture preflight
  was false for the inspecting process; no TCC database was edited and no capture
  permission was falsely claimed. The actual native app's captures still have to
  pass under its own process identity. Sandbox-only inspection saw no display.

The effective protection against automatic untrusted code on the personal Mac is
that there is **no registered listener**, and the replacement requires explicit
reviewed local execution. Merely labeling a public-repository runner or adding a
job condition would not have protected the host: a PR can alter workflow YAML.
The new workflow gates only read commit statuses and cannot schedule local work.

The inactive software/cache may be removed later from this private `CI` directory
if no longer wanted; do not delete an unrelated installation or runner. Nothing
needs to be deregistered. Do not restore the weaker fork approval policy merely
to remove unused binaries.

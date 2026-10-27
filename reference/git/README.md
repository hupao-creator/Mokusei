# Frozen Git application reference

Inactive TypeScript application source retained as a behavior reference, with project names aligned to Mokusei. These files are not registered, built, packaged or executed. No npm manifest or build configuration is retained.

The active replacement is `internal/plugins/applications/git` (Go runtime) and `app/macos/Sources/Host/Git` (SwiftUI/AppKit). See [native Git implementation](../../app/macos/Sources/Host/Git/README.md) and [the plugin contract](../../internal/core/plugin/README.md). Core managed Git worktrees remain in `internal/services/workspaces`.

# Moku Note exposure evidence

An exposure means a foreground viewport made one exact nonempty Note revision
available for complete reading. It does not assert attention, understanding,
approval or that an unreported revision was unread. The [Moku guide](../internal/services/moku/README.md)
owns Note content/context and the [model](../internal/core/model/README.md)
owns the public receipt schema.

## Native qualification

The production Note reader tracks supported rendered content and viewport
coverage for its current reading revision. It requires visible/foreground,
fully admitted Note content, valid layout and a stable two-second viewport dwell. Gaps in a
long note remain gaps until traversed; short-note exposure requires the same
qualification rather than mere mounting. Unsupported content does not acquire
fabricated coverage. Content changes, closure, covering or owner replacement
revoke the prior qualification. Hidden retained text has no exposure authority.

[NativeMokuNote](../app/macos/Sources/Host/MokuScene/NativeMokuNote.swift) and the
shared [Markdown renderer](../app/macos/Sources/Shared/PluginUI/Reading/NativeMarkdownView.swift)
supply the actual content/viewport boundary. The sender is bound to the exact
Note incarnation/revision and native scene lifetime.

## Runtime acceptance

`moku:record-note-exposure` accepts only `noteId`, a positive safe `revision`, and
`complete-viewport-coverage-v1`. It rejects client text, time and extra fields.
Runtime reads the current authoritative exact text inside the writer transaction;
only its current nonempty incarnation/revision can be retained. Duplicate/stale
receipts make no durable write or notification. The accepted exposure changes
catalog evidence without changing Note update time or creating a lifecycle wake.

One mounted Note owns its coverage union; two windows cannot combine partial
ranges. Document/layout changes discard incomplete coverage. Adjacent ranges
merge with a 1pt tolerance, and completion requires full vertical coverage with
horizontal body containment. Repeated visits retain the merged union, not an
unbounded list of samples. These tolerances are implementation rules, not an
assertion that human reading occurred.

A Note update compares incarnation, content revision and `readingRevision` in the
same transaction. On mismatch it returns current Note/evidence without mutation.
Moku context receives the retained exact exposure text and identity rather than
inferring read state from `updatedAt` or an open panel. Note lifecycle, attachment
and conversation ownership remain independent.

Source: [Runtime Moku](../internal/core/runtime/moku.go),
[commands](../internal/core/model/command_validation.go),
[Moku context](../internal/services/moku/context.go).

No Swift-to-Runtime exposure correctness replay is configured in this source tree. The [Note performance probe](../tools/verification/moku-note-performance/README.md)
measures synthetic native preparation and shell work; it does not prove receipt
arrival or next-execution context delivery.

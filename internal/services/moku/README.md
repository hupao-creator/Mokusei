# Moku coordination

[coordinator.go](coordinator.go) owns Moku's conversation, admission queue, saved/applied execution configuration and native handle. [ports.go](ports.go) declares injected Runtime capabilities. Ordinary tasks remain Runtime-owned; Moku coordinates them through admitted tools and lifecycle facts.

Startup recovery prepares native configuration without reserving the settings
admission gate. Runtime verifies the captured source and settings revision before
applying it, so slow catalog discovery does not block a prompt save and a newer
edit wins a recovery race. User input retains the full admission gate through
native acknowledgment; recovery itself never submits a task.
The coordinator's serial queue observes cancellation while waiting, so abandoned
input and voice preparation release their claims before a slow owner finishes.
Cancellation of a waiter does not interrupt the admitted owner.

If an execution ends while preparing its follow-up, Runtime checks saved versus
applied settings before admitting a successor. The coordinator prepares fresh
settings, instructions and context once when Core confirms that no input was
consumed. This covers typed, lifecycle-event and durable outbox inputs. An exact
native `ErrExecutionEnded` can provide that guarantee; wrapped or uncertain
native failures cannot authorize replay or clear an uncertain outbox attempt.

## Tools and creation

[tool_schema.go](tool_schema.go) composes tool schemas from Harness declarations. Inclusive property hints expose choices from closed union branches without replacing their exact validation. [schema_validation.go](schema_validation.go) and each Harness validate the actual request before execution.

Fixed tool schemas compile once per installed binding and are reused for that
configuration generation. Dynamic target schemas remain freshly discovered and
validated at creation admission.

[tools.go](tools.go) implements `list_threads`, `create_thread`, `describe_native_harness`, `get_thread_status`, `send_to_thread`, `interrupt_thread`, `read_thread`, `read_clipboard`, `talk` and `update_note`. Tool calls and results are audited under the owning Moku execution; cancellation follows the captured owner. Creation success means the target input was admitted, not that its work has completed. Listing and reads retain bounded, explicit public access.

### Local clipboard text

`read_clipboard` is read-only and must be called only when the user explicitly
requests it. Its description warns that clipboard content may contain secrets
and will be sent to the model. There is currently **no per-tool UI confirmation**;
this instruction is model guidance, not an enforced approval mechanism. macOS
may independently show a pasteboard access prompt. Never retry automatically to
bypass a permission choice.

Input is an object with only optional integer `maxCharacters` (minimum 1,
default 4000, maximum 20000); unknown properties are rejected by the existing
tool schema boundary. Output is
`{"ok":true,"text":"hello","empty":false,"truncated":false,"characters":5}`.
`characters` counts returned Unicode code points, including whitespace, rather
than bytes or grapheme clusters. A confirmed empty plain-text value returns
`{"ok":true,"text":"","empty":true,"truncated":false,"characters":0}`.

[clipboard.go](clipboard.go) applies a two-second deadline linked to the existing
tool/owner cancellation scope. The reader returns at most `maxCharacters * 4`
UTF-8 bytes, plus one fixed protocol byte; Unicode truncation preserves complete
code points and reports either byte or character truncation. Invalid UTF-8 in
the returned text fails rather than silently replacing bytes. The macOS helper
is killed on cancellation/timeout, has a bounded stdout writer, discards stderr,
and does not include process output or clipboard text in errors.

[clipboard_darwin.go](clipboard_darwin.go) uses the macOS-provided
`/usr/bin/osascript -l JavaScript` AppKit bridge to request only
`public.utf8-plain-text`. It does not read HTML, RTF, EPS, images or the file-URL
pasteboard type, and does not coerce those types into text. A plain-text string
that happens to contain a URL is still text. `pbpaste` was rejected because its
own manual documents that even `-Prefer txt` falls back to RTF/EPS and cannot
restrict reads to one type. This alternative adds an operating-system JXA/AppKit
dependency, no third-party package, Swift client change or compiled helper.
AppKit may materialize the full pasteboard NSData inside the short-lived helper;
the byte bound limits its output and Go-side retention, not pasteboard-server or
helper peak memory.

A nil/unavailable plain-text value (including no such type, an actually empty
pasteboard with no declared text type, denial, or a pasteboard failure) is
**indeterminate**, never reported as empty. Only a successfully obtained zero-byte
plain-text value proves empty. The helper makes one data request without retries.
Non-macOS builds return an explicit unsupported error through
[clipboard_other.go](clipboard_other.go).

Data flows from the OS clipboard through the bounded helper to the tool result
and native model. [transcript.go](transcript.go)'s `completeTool` branches on the
persisted operation name: `read_clipboard` success records only `ok`, `empty`,
`truncated`, `characters` and `redacted:true`; errors record only
`redacted:true` with the ordinary `isError` flag. Raw text and error payloads
never enter that tool-result audit row. Termination and startup recovery also
mark pending clipboard results `redacted:true`, retaining their fixed lifecycle
error and `isError` flag. Other tools keep their existing audit
behavior. Native Harness/provider history and subsequent model messages may
still retain or quote returned text; this change does not redact those owners.

Tests inject a reader per Coordinator, exercise the registered binding and
transcript update, and run the real JXA bridge against synthetic NSData without
accessing the system clipboard. Run the non-darwin implementation test on macOS
by explicitly selecting source files (Go ignores file build constraints in this
mode):
`./scripts/go.sh test internal/services/moku/clipboard.go internal/services/moku/clipboard_other.go internal/services/moku/clipboard_other_test.go`.
This verifies the unsupported source implementation, not a Linux runtime.
Real interactive clipboard permission behavior requires separate manual testing.

Every `create_thread` call supplies `worktree` as a boolean. `false` uses an explicit existing directory or allocates a temporary workspace. `true` requires an explicit committed Git workspace. The result distinguishes base `workspace.cwd` from execution `workspace.worktreeCwd`. Optional `worktreeName` is a directory label, never the task title; [workspace rules](../workspaces/README.md) define validation, normalization, collisions and reported adjustments.

Ordinary tasks require the target Harness's explicit model/thinking choices. Codex also requires service tier. Deferred native targets use `describe_native_harness` for the exact current schema; cached discovery is not admission authority. Moku's own concrete execution profile is independent of ordinary task defaults.

Moku always uses its built-in coordination instructions. Saved routing guidance is appended separately; settings do not expose additional system instructions or replace the built-in prompt.

## Talk and notes

The built-in prompt defines the user's visible communication surfaces as Talk,
the persistent note, and all content in ordinary Agent Threads, including Moku's
delegated instructions. Moku's own assistant messages, including normal and final
replies, are not visible and do not count as communicating with the user. Anything
the user needs to know or respond to must reach a visible surface: Talk for short
immediate answers, questions, confirmations and updates; the note for persistent
milestone recaps; and the relevant Agent Thread for detailed task discussion and
deliverables. Runtime voice delivery remains separate.

`talk` accepts only nonblank `text`, without NUL, up to **160 Unicode code points**, including whitespace/newlines. Rejection does not truncate or overwrite a successful message. The UI derives display identity from the audited operation, not from arbitrary model prose. Code-point budgets are independent from the UI's four-line reading viewport. Each Talk message bubble is visible to the user for about one minute and automatically hides after 60 seconds. [prompt.go](prompt.go)'s shared `TalkTextPolicy` supplies this visibility guidance to the registered tool and parameter descriptions and the built-in Moku prompt, including coordination reached through voice. Use `update_note` for the persistent milestone recap; Talk messages are not copied into the note.

`update_note` requires `text` and an `expected` basis containing `noteId`,
`revision`, and `readingRevision`; `expected:null` applies only before the first
note. Text allows **1200 Unicode code points**. Exactly `""` clears it; other
whitespace-only or NUL-containing values fail. A matching transaction returns
`{ok:true,state}` with the committed note and evidence. A changed basis returns
`{ok:false,code:"note_state_changed",state}` without writing, so Moku can
reconsider. The owner Thread is fenced in the transaction, including after a
history reset. Host replacement preserves the note and its one exact old-text
exposure; clear revokes exposure but retains the incarnation.

[context.go](context.go) adds a bounded JSON note state before every outgoing
Moku input, including user, task-event and voice paths. An absent or cleared note
is explicit. It carries the current text, basis and at most one exact exposed
earlier version. The evidence is presentation, not approval; useful decisions,
constraints, unresolved work and pending review remain eligible for the recap.
The state is not copied into the transcript. Talk supplies short immediate
updates. The [Dock](../../../app/macos/Sources/Host/MokuScene/README.md) owns
presentation and viewport evidence collection.

## Context and voice

Moku collects registered [Context contributions](../../hosts/contexthost/README.md) at their declared hooks. Harness-native model/account facts retain their owners.

Outgoing workspace context reads the Thread catalog only when a directory tag
needs resolving. Explicit directory mentions and inputs without a directory tag
do not load unrelated Thread histories.

[voice.go](voice.go) owns media leases and device/owner fencing. A Codex Moku uses its native voice capability and fails if unavailable; it does not fall back to a relay. Other hosts use the Codex relay with their normal target admission. Ending Moku media leaves already admitted task work running. Typed dispatch and accepted handoffs fence old delivery; caption fragments do not create a new task generation. See [Codex voice](../../plugins/harness/codex/README.md#voice) and the [native media client](../../../app/macos/Sources/Voice/README.md).

Relay requests still waiting for target admission belong to the media lease and
leave the queue when that lease ends. Once admission begins, the service owns
the request independently of media cancellation.

Relay media belongs to the Moku conversation and survives same-owner model,
routing and target-schema changes. Reopening the task engine retains the media
identity and exact spoken-result ownership. Native media belongs to its native
handle; replacing the Moku Thread or explicitly stopping voice still retires
media and waits for cleanup.
Before reopening a same-owner handle, Moku captures pending terminal replies
from that handle. Delayed terminal handling can therefore deliver the exact
native reply after replacement, rather than losing it or substituting a summary.

Native voice does not admit a new task with pending execution configuration.
The authenticated owner can continue its existing call through configuration
reconnection. A captured handoff is eligible for automatic resubmission only
when the adapter confirms that no Core execution or injected tool was admitted
and the retired native process has drained. Cleanup failure, explicit media stop
or lost ownership revokes that recovery. Unknown native failures remain errors,
never permission to repeat a potentially consumed request.
Native Moku speech waits for the same device's delivery-ID readiness receipt
before producing audio. Duplicate receipts cannot replay the reply, and media
stop/generation retirement cancels waiting speech. This handshake gives the
client a playback boundary without guessing ordering between sideband polling
and WebRTC events; relay and private-discussion speech keep their existing path.

Verification: `./scripts/go.sh run -race ./tools/verification/moku` and `./scripts/go.sh test -race ./internal/services/moku` from the repository root. The runner also exports production-shaped Talk/dispatch/note records for native UI replays.

## Durable completion notifications

Ordinary Thread terminal transitions write a Moku outbox entry in the same SQLite
transaction as the observation. The coordinator drains it at startup and once per
second, retrying failures before native Send (including unavailable configuration
and pending user interaction). Admission removes the entry durably; metadata
updates do not create duplicate deliveries. Thread deletion and history reset
remove their pending facts. Native admission is not proof of task completion.
When this outbox is available, ordinary terminal commits bypass the in-memory
event queue and its duplicate tracking. Configurations without the outbox retain
the live notification path. Already queued Moku terminal audit settlement stays
local and drains during shutdown.

Before entering native Send, Runtime persists an uncertain attempt. A transport
failure or crash in this interval cannot prove whether the provider consumed the
notification, so this entry is retained and never automatically replayed. Moku
reports `moku-delivery-uncertain` with the recovery command. Use authenticated
`moku:deliveries` with no arguments to inspect pending facts. Restart the runtime
to fence the old native workers, inspect the native conversation, then invoke
`moku:resolve-delivery` with one object containing `id` and `decision`:
`retry-confirmed-unadmitted` only after confirming non-admission, or
`acknowledge-confirmed-admitted` after confirming admission. Decisions are audited;
the current runtime cannot reconcile its own uncertain attempts. Exactly-once
provider effects cannot be guaranteed without provider idempotency support.

Overview directory context carries `directoryScopeId`, the stable host-derived scope identity. Display tags never resolve a selected directory by basename. Explicit directory mentions still take precedence; an unresolved selected scope reads one catalog snapshot and includes only directories in that scope.

A coordinating-Harness change starts its required new native session and preserves the prior session as read-only `mokuHistory`. Its original Harness keeps ownership of the opaque conversation representation; Moku does not merge native formats. An explicit history reset removes the current conversation and these prior sessions.

Cross-Harness memory consists only of the existing note. Replacement copies its
exact state, and the next outgoing input includes it through the ordinary note
context path. Empty notes stay empty. Switching does not request compact or
generate a summary. Runtime requires idle ordinary tasks and Moku both when
saving a different Harness preference and when replacing the native owner;
unrelated configuration edits keep their existing admission behavior.

Notes can contain `[label](mokusei://execution?threadId=THREAD_ID&executionId=EXECUTION_ID)`
to reference one ordinary Agent Thread execution. Moku obtains the two identities
from thread lifecycle reports; this capability adds no query tool or reason to
query proactively. Capability guidance leaves link selection to the model. The
full Markdown URL counts toward the existing 1200-code-point limit.

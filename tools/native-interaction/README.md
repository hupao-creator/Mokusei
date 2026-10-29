# Operate the macOS UI from code

Launch a built application with an explicit profile and a socket inside an
existing private directory. Use a separate profile for chaos testing. Normal
launches expose no automation endpoint.

```sh
automation_root="$(mktemp -d /private/tmp/oa-interaction.XXXXXX)"
open -n "/absolute/path/Mokusei.app" --args \
  --data-dir "$automation_root/profile" \
  --automation-socket "$automation_root/ui.sock"

python3 tools/native-interaction/client.py --socket "$automation_root/ui.sock" snapshot
python3 tools/native-interaction/client.py --socket "$automation_root/ui.sock" \
  perform '{"name":"settings.open"}'
python3 tools/native-interaction/client.py --socket "$automation_root/ui.sock" \
  perform '{"name":"settings.select","section":"general"}'
python3 tools/native-interaction/client.py --socket "$automation_root/ui.sock" \
  perform '{"name":"settings.close"}'
```

A raw development executable also accepts `--runtime /absolute/runtime/path`.
The socket path must fit macOS's Unix socket limit (at most 103 UTF-8 bytes).
Its parent must belong to the current user with mode 0700. The endpoint is mode
0600 and accepts only same-user peers. An occupied path is never removed on
startup. Normal Quit removes the owned socket; after a crash use a fresh directory.

## Protocol 1

Each connection exchanges one UTF-8 JSON object per newline. Requests are at most
64 KiB, nesting at most 16. Up to eight connections are supported, with 30-second
idle expiry and at most 2 MiB of queued output per client. Requests execute in
arrival order on the UI's main actor; response sequence is process-wide. Use one
client when order matters. Oversized frames/output or stalled clients are closed.

```json
{"protocol":1,"id":"inspect-1","op":"snapshot"}
{"protocol":1,"id":"action-1","op":"perform","action":{"name":"settings.open"}}
```

`id` is a caller correlation string (1–128 UTF-16 units), not a deduplication key.
Do not automatically retry an uncertain action. Each response contains
`protocol`, `id`, `session`, `sequence`, `pid`, `ok`, `error` and `snapshot`.
`error` is null on success, otherwise `{ "code": "…", "message": "…" }`.
Codes are `invalid_request`, `unavailable`, `not_found`, `blocked` and `stale_control`.
Unknown/missing fields and invalid argument types are rejected.

| Action name | Additional fields | Admission |
| --- | --- | --- |
| `settings.open` | none | Loaded Overview mounted, Settings closed |
| `settings.select` | `section` | Current Settings section ID |
| `settings.control` | `controlId`, `handle`, `operation`, `value` | Current mounted, enabled control and current handle |
| `settings.close` | none | Settings open and its close gate permits |
| `overview.show` | none | Another page open; closes Settings through its gate |
| `navigation.back` | none | Current page's back action; respects nested reading |
| `thread.open` | `threadId`, `typeId` | Target in the current Overview snapshot |
| `search.begin` | none | Overview with search closed |
| `search.update` | `query` | Search open; empty query is supported |
| `search.end` | none | Search open |
| `filter.select` | `filterId` | Overview; null selects All |

Navigation text arguments are bounded to 4096 UTF-16 units. Settings text controls
accept at most 20000 UTF-16 units, so the real 12000-unit field validation can be
exercised. Send UTF-8 directly rather than expanding every character to a JSON escape. Discover IDs from `snapshot`:
`actions`, `settingsSections`, `filters` and `threads`. Never derive filter IDs
from labels. Availability can change between observation and dispatch.

Snapshot also includes `page`, `selectedThread`, `settingsSection`, `search`,
`selectedFilterId`, `mounted`, `transitioning`, `runtimeAvailable`,
`settingsSaving`, `settingsCloseBlocked` and `errors`. During startup/reload it
can be null. Settings/thread mounting is observed from the production page.
An immediate reply describes accepted intent, not a completed frame. Poll the
desired postcondition over repeated observations with `mounted: true` and
`transitioning: false`. This does not promise that every decorative animation,
search worker or settings save has finished; those facts remain separate.

## Chaos and trace replay

```sh
python3 tools/native-interaction/client.py --socket "$automation_root/ui.sock" \
  monkey --seed 42 --steps 200 --trace /private/tmp/chaos-42.jsonl
python3 tools/native-interaction/client.py --socket "$automation_root/ui.sock" \
  replay /private/tmp/chaos-42.jsonl --trace /private/tmp/chaos-42-replayed.jsonl
```

The standard-library navigation runner sorts an explicit set of supported
choices, uses a seeded PRNG, waits for postconditions on normal steps, and
intentionally skips animation waits on 30% of steps. It checks a random candidate
again before dispatch. A candidate that has become unavailable is recorded as
`candidate-refresh`; a definite `unavailable` or missing-target rejection whose
response snapshot confirms the change is recorded as `candidate-rejected`.
Neither counts toward the requested number of successful steps. The next choice
uses a fresh snapshot. Other rejections, surfaced UI errors, violated route
invariants, transport failure and bounded wait/overall deadlines still fail.
The default overall budget is 120 seconds, checked between attempts; each request
is bounded to five seconds and each settling wait to eight seconds. Custom
navigation monkeys can pass their selection snapshot as `candidate_state` to
`step`; its `None` result means no action was applied. Directed `step` calls keep
strict rejection behavior.

Trace files are new private files, never overwritten. Each action and its before
state are flushed **before** sending; response and settled state follow. A crash
therefore leaves the last attempted action. Replay skips confirmed stale
rejections and submits the remaining recorded actions and expected error codes,
including an action whose response was lost; it does not retry an uncertain
action in the original session. Restore the same fixture,
IDs and initial page/search/filter state before replay. Seeds reproduce choices
only under the same observed state; traces preserve the actual chosen sequence.
The navigation runner covers reading, search and filtering. The Settings runner
below exercises actual form controls. Neither runner sends model tasks or tests
physical pointer/gesture fidelity.

Run the [isolated production app replay](../verification/native-interaction/README.md)
to verify the bridge with a repeatable seeded fixture without user data.

## Mounted Settings controls

`snapshot.settings.glassWorld` reports the saved, live client preference. The
General Toggle is `general.glassWorld` and accepts `set` with a Boolean. It saves
locally even without a connected Runtime; a failed write retains its old value
and surfaces the page notice.

`snapshot.settings.controls` lists the controls actually mounted in the current
Settings visit and section. Each has a stable `id`, ephemeral `handle`, `kind`,
`value`, `enabled`, `operations` and `pending`. Selects expose option IDs and their
availability; textareas expose validation and composition state. Notices expose
severity/message without an operation. Password inputs, installs, credential
editors and history deletion are not registered.

```python
from client import Client

client = Client("/private/tmp/my-run/ui.sock")
client.request({"name": "settings.open"})
client.request({"name": "settings.select", "section": "moku"})
state = client.settle(lambda s: any(c["id"] == "moku.routingEnabled"
    and not c["pending"] for c in s["settings"]["controls"]))
toggle = next(c for c in state["settings"]["controls"]
    if c["id"] == "moku.routingEnabled")
response = client.request({"name": "settings.control", "controlId": toggle["id"],
    "handle": toggle["handle"], "operation": "set", "value": True})
assert response["ok"], response["error"]
state = client.settle(lambda s: any(c["id"] == "moku.routingGuidance"
    and not c["pending"] for c in s["settings"]["controls"]))
control = next(c for c in state["settings"]["controls"]
    if c["id"] == "moku.routingGuidance")
response = client.request({"name": "settings.control", "controlId": control["id"],
    "handle": control["handle"], "operation": "set", "value": "Prefer small tasks 🚀"})
assert response["ok"], response["error"]
client.close()
```

Select operations use `select` with an advertised option ID; toggles use `set`
with a Boolean; buttons use `activate` with null. Textareas support `set`,
`compose`, `commit` and `blur` (null). They invoke the actual NSTextInputClient
and editing delegates. Non-secret single-line inputs use their actual Binding.
Plugin callbacks retain responsibility for dependent choices and incomplete
profiles. This is not an arbitrary settings JSON mutation API.

Observe again after each operation and wait for `pending: false`. Handles are
fenced by mounted owner, page visit, section, descriptor and render refresh.
Old handles are rejected instead of applying captured bindings to a new field.
`settings.status`, `revision`, `catalogRevision`, `composing`, `invalidField`,
`conflicted` and `error` describe save progress independently of frame readiness.
An `ok` response does not promise persistence. Read Runtime public `state:load`
when an independent persistence oracle is required.

```sh
python3 tools/verification/native-interaction/settings.py --steps 100
```

This launches a signed production Release app and its bundled Runtime with normal
native Harness discovery. Each seed has a fresh private profile. Directed cases
cover preferences, real text editing/IME/UTF-16 limits, CAS conflict retry/discard,
model-dependent choices, dispatch targets and application inheritance. Moku
routing guidance remains editable; additional instructions and full system-prompt
replacement/reset controls are no longer part of the product.
The monkey chooses from currently mounted controls. It saves incremental traces,
checks public persisted state, and restarts both app and Runtime to verify settings
and preferences survive. See the [production replay guide](../verification/native-interaction/README.md).

## Mounted reading controls

`snapshot.reading.controls` describes the actual current or historical document.
Each entry has `id`, `handle`, `role`, `kind`, `value`, `enabled`, `operations`,
`pending` and `scope`. A `reading.control` action takes `controlId`, the observed
`handle`, `operation` and `value`. `activate` requires null; the `timeline` role
supports `scrollTo` and `scrollBy` with finite point offsets within ±10,000,000.
Offsets are clamped to the real document bounds through its `ScrollPosition`.
`top` uses the same zero-based coordinate as `scrollTo` and `scrollBy`; the
snapshot also exposes native `contentOffset` and `insetTop`, whose sum is `top`.
This conversion also applies to retained positions when historical pages close.
Observe fresh handles after every command; detached, hidden, disabled or stale
controls reject operations.

| Role | Observation / operation |
| --- | --- |
| `conversation` | Current/history destination, selected historical row, parent visibility, transition state |
| `history.sidebar` | TOC selected/current/focused row identities and total entry count |
| `history.open`, `history.current`, `history.close` | Mounted TOC entry, current-turn and document Back callbacks |
| `turn.author` | Resolved author shown below the active document title |
| `visibility.userMessages`, `visibility.work` | Current document's independent visibility values and toggles |
| `loadEarlier`, `jumpLatest` | Mounted earlier-window and latest buttons |
| `timeline` | Top, content height, viewport, following, visible row IDs/count, first index and total count |
| `execution.group`, `activity`, `disclosure` | Nested execution/tool/thinking disclosure values and toggles |
| `row.load`, `execution.load`, `turn` | Actual Codex row/shared execution load state and mounted turn's rendered row count |

```sh
python3 tools/native-interaction/thread_chaos.py --socket "$automation_root/ui.sock" \
  --thread-id interaction-c --seed 41 --steps 100 --trace /private/tmp/reading-41.jsonl
python3 tools/native-interaction/thread_chaos.py --socket "$automation_root/ui.sock" \
  --replay /private/tmp/reading-41.jsonl --trace /private/tmp/reading-41-replayed.jsonl
```

The runner first exercises history, nested disclosures, scrolling, rejected Settings
entry and stale-handle rejection, then makes seeded choices from mounted controls. A
fixture with more than 120 completed turns and tool details is required to cover
load-earlier and nested tools. The [production reading launcher](../verification/thread-interaction/README.md)
provides that fixture, fresh profiles and signed-app lifecycle management. Launch a fresh signed production app/profile from
the same fixture before replay. Replay resolves each recorded logical control ID
to its new mounted handle; handles from a previous process are never reusable.
The trace records actual coverage, loading failures and every attempted command.
Every scroll asserts its observed final position against the requested/clamped
target within half a point, including repeated relative movement and both edges.
This reading scope excludes composer send/interrupt, attachments, sidecards, Git,
external links and media; page navigation alone does not test those features.

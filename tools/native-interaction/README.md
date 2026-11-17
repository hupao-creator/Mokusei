# Operate the macOS UI from code

Launch a built application with an explicit profile and a socket inside an
existing private directory. Use a separate profile for scripted interaction. Normal
launches expose no automation endpoint. A fresh profile first presents onboarding;
`settings.open` is admitted only after setup completes and a loaded Overview
advertises that action. Launch success alone does not establish readiness.

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
| `filter.select` | `filterId` | Overview; null selects All |

Navigation text arguments are bounded to 4096 UTF-16 units. Settings text controls
accept at most 20000 UTF-16 units, so the real 12000-unit field validation can be
exercised. Send UTF-8 directly rather than expanding every character to a JSON escape. Discover IDs from `snapshot`:
`actions`, `settingsSections`, `filters` and `threads`. Never derive filter IDs
from labels. Availability can change between observation and dispatch.

Snapshot also includes `page`, `selectedThread`, `settingsSection`,
`selectedFilterId`, `mounted`, `transitioning`, `runtimeAvailable`,
`settingsSaving`, `settingsCloseBlocked` and `errors`. During startup/reload it
can be null. Settings/thread mounting is observed from the production page.
An immediate reply describes accepted intent, not a completed frame. Poll the
desired postcondition over repeated observations with `mounted: true` and
`transitioning: false`. This does not promise that every decorative animation,
settings save has finished; those facts remain separate.

## Mounted Settings controls

`snapshot.settings.appearance` and `snapshot.settings.locale` report the saved
client preferences. General exposes `general.appearance` and `general.locale`
selects. They save locally even without a connected Runtime; a failed write
retains its old value and surfaces the page notice.

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
state = client.settle(lambda s: any(c["id"].endswith("routingPreset.custom")
    and not c["pending"] for c in s["settings"]["controls"]))
choice = next(c for c in state["settings"]["controls"]
    if c["id"].endswith("routingPreset.custom"))
response = client.request({"name": "settings.control", "controlId": choice["id"],
    "handle": choice["handle"], "operation": "activate", "value": None})
assert response["ok"], response["error"]
state = client.settle(lambda s: any(c["id"].endswith("routingGuidance")
    and not c["pending"] for c in s["settings"]["controls"]))
control = next(c for c in state["settings"]["controls"]
    if c["id"].endswith("routingGuidance"))
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
| `visibility.work` | Current document's execution visibility value and toggle; Agent detail never offers a user-message toggle |
| `loadEarlier`, `jumpLatest` | Mounted earlier-window and latest buttons |
| `timeline` | Top, content height, viewport, following, visible row IDs/count, first index and total count |
| `execution.group`, `activity`, `disclosure` | Disclosure values/toggles only on surfaces whose reader policy mounts them; ordinary Agent detail is summary-only |
| `row.load`, `execution.load`, `turn` | Actual Codex row/shared execution load state and mounted turn's rendered row count |

Settings uses a horizontal header. Report/Tag modes are exposed through
`<section>.off`, `<section>.inherit` and `<section>.independent` activation
actions. Independent Harness seats use `<section>.harness.<id>`; inherited mode
shows read-only execution fields, while off hides execution fields.
Moku exposes Economy, Balanced, Performance and Custom actions with
`routingPreset.<id>` field suffixes. The current mounted scope prefixes their
full IDs; use observed `id`/`handle`, not a fabricated prefix. Custom reveals
the `routingGuidance` editor. Selecting another preset retains the custom text.
There is no `moku.routingEnabled` switch.

## External benchmark scenario entry

`--benchmark-scenario overview` requires both an explicit `--data-dir` and
`--automation-socket`. The App records onboarding completion in that profile
before constructing its ordinary workspace. This prepares the scenario without
changing card data, layout, renderer, input handling or Runtime behavior. Use a
fresh isolated profile. The external [rendering benchmark](../benchmarks/README.md)
creates tasks through public Moku/Runtime commands and uses OS input and pixels
for measurement; it does not write preference/database/session files.

The Overview benchmark entry also requests a fixed 1280 × 820 initial window
and disables scene restoration for that explicit scenario. This removes saved
window geometry as a startup variable; the OS bounds remain externally verified.

## Interaction verification

The [e2e runner](../e2e/README.md) records real mounted-control requests and
postconditions for `E2E-READ-001` and `E2E-SETTINGS-001`, with separate public
Runtime outcome evidence. Scenario definitions do not imply a passing run.
No composer send/pause operation is exposed; HTTP follow-up and interrupt
commands do not establish composer interaction coverage.

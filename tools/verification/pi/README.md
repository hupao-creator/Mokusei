# Pi integration replay

`./scripts/go.sh run -race ./tools/verification/pi` runs the real Go adapter against a self-executing protocol fixture. `-mode native` uses the installed external Pi CLI with a loopback scripted model service; `-mode all` runs both. `-artifacts <directory>` retains JSON evidence. `-timeouts` includes real startup/request timeout cases.

`./scripts/go.sh run -race ./tools/verification/pi -swift-usage -timeout 10m`
additionally feeds 60 Go-produced durable/overview/thread/execution/turn fixtures
through the real Swift Pi plugin and checks the Overview card and execution-usage
API. The deterministic replay covers per-call native fields (including cache,
reasoning and native `totalTokens`), running accumulation, zero/missing usage on
failed requests, retry streaming, reopen and execution isolation. `-artifacts`
retains `usage-fixtures.json`; no user profile or model service is involved.
The native mode also checks real installed Pi `message_end` usage against the
loopback provider's fixed 25-token response.

`-mode native-shutdown` checks only installed Pi disposal, without sending a
model request: a real asynchronous `session_shutdown` hook must release its
temporary lock before adapter Close returns. The deterministic replay also
checks EOF cleanup and bounded termination of a child that ignores EOF/SIGTERM.

The real Pi 1.0.0 scenario exercises the native loader, host extension, read guard, Go tool callback, persistence, independent clone, cancellation and recovery. It uses isolated native configuration and a localhost-only sandbox. It does not contact a paid model, use account login or prove future Pi compatibility.

The installed-native run also checks a loopback Responses model: explicit thinking
selection must reach the actual HTTP request as `reasoning.effort=high`, with the
exact model and final reply preserved. Deterministic cases reject missing effort
mappings, unsupported/disabled choices and custom request overrides. This covers
the transport used by native xAI OAuth models without reading account credentials.

The installed-native Chat replay covers Pi's omitted compatibility defaults:
DeepSeek off/low/high/max selection must remain available to ordinary Threads
and reach the wire as `thinking.type` and `reasoning_effort`. It also checks native
provider/URL defaults that disable effort forwarding, explicit true/false
overrides, and rejection of unsupported effort choices. These requests use only
loopback endpoints and disposable native configuration.

The native mode also drives real Pi `DiscussionPreparer` through the production
threadvoice relay with synthetic media: private history continuity, Core reads,
forbidden write, concurrent questions, provider errors, cancellation/media failure
cleanup, lazy forks and an actively running source remaining unchanged.

The deterministic replay also sends an editor request from the RPC child process, checks its multiline Unicode prefill in the committed public form, and submits the unchanged default through production preflight and native response.

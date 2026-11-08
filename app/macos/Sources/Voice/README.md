# Native voice

[NativeVoiceCoordinator.swift](NativeVoiceCoordinator.swift) coordinates Overview's global Moku media client and retained Thread transcript readers. [NativeVoiceMediaClient.swift](NativeVoiceMediaClient.swift) owns an attempt through preparation, permission, SDP, connection, polling and stop. [NativeWebRTCMedia.swift](NativeWebRTCMedia.swift) owns the microphone, WebRTC peer, audio and ordered data channel. Platform audio-session/device routing is adapted here, while [Go](../../../../internal/plugins/harness/codex/README.md#voice) owns native authentication and sideband handoffs.

Media starts only through an explicit action and successful current-owner preparation. Workspace/device/attempt/session identity rejects old asynchronous completions. Replacing owners, disconnecting or ending the media attempt cancels its resources; merely rendering a cloud, Dock or Sidecard does not start capture. Moku task work already accepted by the host survives ending Moku media.

A late occupied-owner preparation response cannot change the current device
notice or takeover token. A late response that allocated a session still cleans
up that obsolete session using its own request identity.

Native Moku settings changes use an automatic, ownership-fenced media reconnect
when the native peer cannot replace its complete execution configuration. This
continues the user's existing call intent and mute state; it is not permission
to start an idle call. Explicit Stop, disconnect and ownership replacement win
over late reconnect completions. Failed reconnection remains visible rather than
starting an unbounded retry loop. The native ownership suite uses the production
client and controlled media/backend boundaries to exercise this behavior.

Native Moku reply playback uses a delivery-ID readiness acknowledgement before
the adapter starts the audio response. This orders pending speech ahead of the
WebRTC response/buffer events even when sideband polling is delayed. Reconnection
waits for the current utterance and playback buffer to settle; a peer already
confirmed retired does not wait for events it can no longer produce. Direct
realtime replies without a task handoff use the ordered media response boundary.

## Typed input and speech

[NativeVoiceProtocol.swift](NativeVoiceProtocol.swift) tracks generating and buffered response identities separately. At a typed-input action the client synchronously cancels the observed response and clears active buffered audio over the ordered data channel before dispatch. `response.done` does not prove the playback buffer drained. Interrupted identities prevent delayed events from reviving an old response. Buffer clearing is not deferred/retried by a later caption or rejected submission.

The Host captures that typed-input fence only for the first admission attempt
of a logical Moku submission. It keeps the original voice input ID and
Report/directory source with the submission while recovering an uncertain
response. Retrying the saved input queries its receipt rather than fencing the
current media again; a newer response keeps playing. The durable receipt remains
protected until the original persisted draft is consumed, and blocks a reopened
owner that has lost the submission context. The native ownership replay drives
this path through the production Host sender and loopback Runtime client.

Business input/result ownership uses sideband generation fences, not VAD/caption timing. A nonterminal `speech-error` preserves the media session; connection/protocol errors end it. Accepted speech transport does not prove audible playback, and uncertain speech is not resent automatically.

## Transcripts and visualization

User transcript projection keeps stable session/item identity through partial and final snapshots. Final cannot regress to partial. An assistant item consumes the current visible input only on its first nonempty output; an explicitly associated Moku answer consumes the matching input. Consumed items cannot reappear from late finals. Duplicate events, old sessions and replaced attempts cannot affect the current projection. When no unique handoff/ASR relationship exists, the adapter does not guess one from the latest text.

[NativeVoiceCaptureAnalyser.swift](NativeVoiceCaptureAnalyser.swift) reads bounded capture samples for visual metering and emits scalar loudness/onset state. It does not provide a wake-word detector or historical PCM injection path. [VoiceControls](../Host/VoiceControls/) and the shared cloud consume that state. Rendering demand controls analysis, not microphone authority.

Verification combines the Codex `-voice-only` fixture, Moku and retained Thread history Runtime replays, and native voice ownership/transcript suites. Their Moku prepare responses confirm the requested `superThreadId` and `sourceRevision` before permission or polling. Stop replays record the initial revocation and post-prepare confirmation with the retiring request/session/ownership identity; a held prepare is released before joining that same Stop, and Start remains blocked while cleanup drains. The ownership suite uses the coordinator's single Moku media client lifecycle: startup failures, mute, cancellation, stop/disconnect, return from a reader without automatic restart, and late callbacks after the same client starts a new attempt. Cross-device occupied-owner and explicit takeover identities remain covered. Removed Thread media takeover, suspension and restoration paths have no replay entry; retained Thread transcript readers remain covered by Runtime history replays. Physical microphone, WebRTC playback and audio-route changes require separate Mac hardware validation.


Voice calls are available only from Overview's global Moku. Ordinary Agent
readers, Super Thread readers and Moku history have no start/long-press/accessibility
voice action, live controls or voice background. Entering any reader synchronously
closes the global peer, cancels its capture and requests Stop. A separate visible
notice retains received ASR for copying and exposes pending/failed cleanup. Returning
to Overview never restarts media automatically. A permission prompt's focus change
alone is not navigation. Text/attachments retain their existing send targets.

The ordinary Thread `voice` Sidecard keeps its stable identity solely as **Past
voice transcripts**. Its native data source owns no media client. Existing transcript
files and history remain readable, including when a Harness cannot execute; there
is no discussion start/mute/stop control or newly created private voice fork.

A media Attempt retains its exact prepare Task. Stop first revokes the ownership
request, then drains the prepare outcome and confirms another Stop using any returned
session identity. Until both settle, the retiring Attempt blocks Start and cannot
be dismissed as closed. Late preparation never launches an independent `try?`
cleanup. Failures retain ownership, session and error for the same Stop retry;
configuration reconnect's predecessor also receives explicit cleanup. The backend
revokes stopped preparation IDs even when Stop arrives before prepare.

Native voice admission carries an internal session marker; non-voice background
continuations do not need a voice lease. Accepted task work survives media shutdown.
Unadmitted speech is not automatically resent, and audio that has not been transcribed
cannot be recovered by the client. This sprint verifies only static code, lint and
product builds, not microphone, WebRTC, UI interaction or timing replays.

# Native voice

[NativeVoiceCoordinator.swift](NativeVoiceCoordinator.swift) coordinates Moku and thread-discussion clients. [NativeVoiceMediaClient.swift](NativeVoiceMediaClient.swift) owns an attempt through preparation, permission, SDP, connection, polling and stop. [NativeWebRTCMedia.swift](NativeWebRTCMedia.swift) owns the microphone, WebRTC peer, audio and ordered data channel. Platform audio-session/device routing is adapted here, while [Go](../../../../internal/plugins/harness/codex/README.md#voice) owns native authentication and sideband handoffs.

Media starts only through an explicit action and successful current-owner preparation. Workspace/device/attempt/session identity rejects old asynchronous completions. Replacing owners, disconnecting or ending the media attempt cancels its resources; merely rendering a cloud, Dock or Sidecard does not start capture. Thread discussion cleanup is distinct from the source task; Moku task work already accepted by the host survives ending Moku media.

A late occupied-owner preparation response cannot change the current device
notice or takeover token. A late response that allocated a session still cleans
up that obsolete session using its own request identity.

## Typed input and speech

[NativeVoiceProtocol.swift](NativeVoiceProtocol.swift) tracks generating and buffered response identities separately. At a typed-input action the client synchronously cancels the observed response and clears active buffered audio over the ordered data channel before dispatch. `response.done` does not prove the playback buffer drained. Interrupted identities prevent delayed events from reviving an old response. Buffer clearing is not deferred/retried by a later caption or rejected submission.

Business input/result ownership uses sideband generation fences, not VAD/caption timing. A nonterminal `speech-error` preserves the media session; connection/protocol errors end it. Accepted speech transport does not prove audible playback, and uncertain speech is not resent automatically.

## Transcripts and visualization

User transcript projection keeps stable session/item identity through partial and final snapshots. Final cannot regress to partial. An assistant item consumes the current visible input only on its first nonempty output; an explicitly associated Moku answer consumes the matching input. Consumed items cannot reappear from late finals. Duplicate events, old sessions and replaced attempts cannot affect the current projection. When no unique handoff/ASR relationship exists, the adapter does not guess one from the latest text.

[NativeVoiceCaptureAnalyser.swift](NativeVoiceCaptureAnalyser.swift) reads bounded capture samples for visual metering and emits scalar loudness/onset state. It does not provide a wake-word detector or historical PCM injection path. [VoiceControls](../Host/VoiceControls/) and the shared cloud consume that state. Rendering demand controls analysis, not microphone authority.

Verification combines the Codex `-voice-only` fixture, Moku/thread Runtime replays and native voice ownership/transcript suites. Physical microphone, WebRTC playback and audio-route changes require separate Mac hardware validation.

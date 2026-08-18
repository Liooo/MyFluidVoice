# Soniox v5 Streaming Dictation Design

## Goal

Add Soniox `stt-rt-v5` as a private, bring-your-own-key cloud speech model for normal
MyFluidVoice dictation. It must provide genuine low-latency partial transcription, use the active
keyboard input source to guide or restrict the spoken language, and preserve FluidVoice's existing
recording, VAD, session isolation, finalization, AI enhancement, history, and output-delivery paths.

The first release is intentionally limited to interactive dictation. File Transcription, Meeting,
dictionary training, and the Local API continue to use a local/system speech model and never send
their audio to Soniox.

## Product Decisions

- This is a private BYOK integration. A user-owned long-lived Soniox API key is stored only in the
  macOS Keychain and is sent directly from the Mac to Soniox.
- No token-broker backend or temporary-key service is included.
- Use the active realtime model ID `stt-rt-v5` rather than a deprecated alias.
- Use one native `URLSessionWebSocketTask` per recording. Do not add a third-party Soniox SDK or a
  JavaScript runtime.
- Connect only when the first audio is ready to send. Do not prewarm an idle billable socket.
- Reuse FluidVoice's existing cumulative-buffer streaming loop. The provider remembers how much of
  the prefix it has sent and transmits only the new suffix.
- Do not reconnect automatically during a recording. Soniox has no resumable stream boundary, so a
  new socket could duplicate, omit, or rebill audio. Fail the owned session cleanly and show a
  sanitized actionable error.
- Do not silently replace a failed Soniox result with partial text or paste an incomplete result.

## Alternatives Considered

### Direct capture-pipeline streaming

Sending 60 ms frames directly from the capture pipeline would shave some scheduling delay, but it
would couple network backpressure to the real-time audio callback and expand the cancellation and
session-lifecycle surface. The existing 100 ms app streaming cadence is sufficiently close to
Soniox's realtime guidance without risking the audio capture architecture.

### Stop-only cloud transcription

Sending the complete recording only after capture stops would be simpler, but it would not provide
live partial text and would not meet the streaming objective.

### New generic cloud-ASR framework

A provider-agnostic WebSocket framework is premature with only one cloud speech provider. Keep the
Soniox protocol implementation private to `SonioxProvider`; extract a broader abstraction only when
a second cloud ASR proves the shared contract.

## Architecture

### Speech model and immutable session binding

Add `SpeechModel.sonioxV5` and a Soniox provider group. The model is marked as cloud/BYOK,
streaming-capable, universal across supported CPU architectures, and requiring no downloaded model
artifacts.

Add a Soniox language binding to the existing immutable `RecordingSpeechConfiguration`. It contains
only non-secret values required for one recording:

- normalized Soniox language code, or no code for automatic detection;
- whether the language hint is strict;
- selected Soniox region.

The active API key is read from Keychain once when the recording provider is constructed and is held
only by that provider. It is never stored in `RecordingSpeechConfiguration`, `providerKey`,
UserDefaults, backups, history, analytics, or logs. API-key editing remains disabled while a recording
or finalization owns the provider.

Every Soniox recording receives a fresh provider and WebSocket state. It must not reuse the cached
provider instance from a previous recording.

### Language handling

Expose one Soniox setting with three choices:

1. `Automatic` — omit `language_hints`; allow multilingual automatic detection.
2. `Prefer Current Input Source` — send the current IME's language as one non-strict hint.
3. `Current Input Source Only` — send the current IME's language as one strict hint.

Default to `Current Input Source Only` for this private Japanese-focused build. A Japanese input
source resolves from `ja-JP` to Soniox code `ja`; a US/Roman input source resolves to `en`. The
setting and resolved binding are sampled at recording start, so changing the IME or setting during a
recording affects only the next recording.

The Soniox supported-language set is explicit and tested. An unsupported or unknown locale uses
automatic detection rather than manufacturing an invalid hint.

### Region and endpoint

Expose:

- `Global` (default): `wss://stt-rt.soniox.com/transcribe-websocket`
- `Japan`: `wss://stt-rt.jp.soniox.com/transcribe-websocket`

The Japan choice explains that it requires a Soniox Japan-region project and its region-specific API
key. Merely changing the hostname does not grant residency. The matching REST base URL is used when
verifying credentials.

### Credential setup and cloud-model UI

Add a Soniox configuration section to Voice Engine with:

- a secure API-key editor;
- `Save & Verify`, using `GET /v1/models` on the region's HTTPS API without sending audio;
- `Remove Key`;
- language-handling picker;
- region picker;
- links to the Soniox console and privacy/data-residency documentation;
- an explicit disclosure that microphone audio is sent to Soniox and usage is billed by Soniox.

The key uses Keychain provider ID `asr:soniox`. Saving an empty field deletes the key rather than
creating an empty credential. `Save & Verify` has a 10-second timeout and replaces the stored key
only after verification succeeds; a failure leaves the prior verified key unchanged. Changing the
region marks the credential unverified until it succeeds against that region. Verification errors
never echo the submitted key or request payload.

The model card uses cloud-specific states:

- `API Key Required`
- `Verifying`
- `Configured`
- `Ready` during an owned recording

It never displays local-model `Download`, `Cached`, or model-file `Delete` actions. Soniox remains
excluded from onboarding because onboarding currently assumes every selectable third-party speech
model is downloadable and ready without credentials.

### Dictation-only scope and local fallback ownership

Soniox can be assigned to a keyboard input source and can also be the global dictation choice. Keep a
persisted non-cloud `localFallbackSpeechModel`, updated whenever the user activates a local/system
model. Existing users initialize it from their current local selection, or from FluidVoice's default
model if the selected value is not suitable. Persist and back up this non-secret fallback setting;
normalize invalid, unavailable, or cloud values back to the current platform default.

Normal dictation resolves Soniox when selected. File Transcription, Meeting, dictionary training,
and Local API transcription explicitly resolve `localFallbackSpeechModel` instead. They do not
construct a Soniox provider or read its API key. Their UI should identify the local engine they will
use when Soniox is the global dictation choice.

This local fallback is a scope boundary, not an automatic recovery path for failed Soniox
dictation. A failed cloud dictation does not trigger an unexpected model load or download.

## Streaming Protocol and Data Flow

### Connection and configuration

At the first streaming call, open the selected WebSocket and send one text configuration frame:

```json
{
  "api_key": "<keychain value>",
  "model": "stt-rt-v5",
  "audio_format": "pcm_f32le",
  "sample_rate": 16000,
  "num_channels": 1,
  "language_hints": ["ja"],
  "language_hints_strict": true,
  "enable_endpoint_detection": false
}
```

`language_hints` is omitted in Automatic mode. FluidVoice owns capture termination and VAD, so
Soniox endpoint detection stays disabled.

The existing 16 kHz mono `[Float]` buffer maps directly to little-endian Float32 PCM. Send only the
new suffix and split it into bounded frames of at most 960 samples (about 60 ms). The speech model's
preview interval and minimum preview duration are both 100 ms. A dedicated receive task continuously
reduces server events. Each preview call awaits connection/send completion, then immediately returns
the actor's latest completed transcript snapshot instead of waiting for a new response. A stored
terminal receive error is thrown by the next preview or final call.

### Response reduction

A private, pure token reducer owns transcript state:

- append final tokens exactly once;
- replace the entire non-final suffix on every response;
- concatenate token text exactly, without inserting guessed whitespace;
- remove Soniox control markers such as `<fin>` and `<end>` from user-visible text;
- retain `error_type` and `request_id` for sanitized diagnostics;
- compute confidence only from transcript tokens that include confidence.

The provider returns the complete `final + current provisional` snapshot expected by FluidVoice's
existing partial-transcription UI, not raw token deltas.

### Finalization

When capture stops:

1. Stop and await the app streaming timer using the existing session-owned flow.
2. Send any PCM suffix that was not sent by the last preview tick.
3. Send 200 ms of Float32 silence.
4. Send `{"type":"finalize"}`.
5. Continue receiving until the final `<fin>` marker.
6. Send an empty binary frame to end the stream.
7. Wait for `{"finished":true}` and return only the accumulated final transcript.
8. Close and clear all socket, receive-task, continuation, token, and sample-count state.

Soniox does not need FluidVoice's one-second local-model padding. The ASR finalization path must pass
the actual captured samples to Soniox and reserve synthetic padding for providers that require it.

Finalization has a 10-second timeout beginning after the finalize control message is sent. Timeout,
cancellation, malformed response, server error, or socket close before `finished` closes the task
and fails the owned recording without late output.

### Cancellation and early exits

`resetAfterCancellation()` cancels the receive task, cancels the WebSocket, resumes every pending
waiter with `CancellationError`, and clears transcript/sample state. It is idempotent.

Discard, app termination, no-audio, and short-silence early returns must all close a Soniox socket if
streaming already began. A cancelled or previous recording may not publish partial text, complete a
new recording, add history, touch the clipboard, or type output.

## Error Handling

Map Soniox's stable `error_type` values into concise user-facing categories:

- invalid or missing key;
- unavailable model or malformed configuration;
- account/project balance exhausted;
- concurrency or rate limit reached;
- temporary service/network failure;
- finalization timeout.

Do not branch on mutable server prose. Show `request_id` when present so the user can contact Soniox
support. Never include the API key, configuration JSON, raw WebSocket frames, or transcript text in
errors or logs.

Show one Voice Engine/overlay error for the owned recording. Dismiss recording UI through the
existing failure path and leave history, clipboard, and typing untouched. A transcript previously
shown as a volatile partial is cleared and is never promoted to final output.

There is no in-session reconnect in the first release. The complete PCM remains governed by the
existing optional local audio-history setting, but a failed cloud request does not force audio to be
saved.

## Privacy, History, and Documentation

- Update the microphone usage text and README privacy section to state that choosing a cloud speech
  model sends microphone audio to that provider.
- Explain that Soniox states realtime audio/transcripts are not retained or used for model training,
  while MyFluidVoice's own optional local history and diagnostic behavior remain separate.
- Do not log Soniox transcript contents. Existing ASR diagnostics for this provider record only
  provider/model, sample count, duration, character count, stable error type, and request ID.
- Record the resolved speech model/provider in history metadata for successful output, with backward-
  compatible optional decoding for old entries.
- Never include credentials in backup/export data.

## Test Design

All protocol tests use an injected fake WebSocket transport; automated tests never call Soniox or
require a real API key.

### Pure and provider tests

- `ja-JP` maps to `ja`; US/Roman maps to `en`; unsupported locales use automatic detection.
- Automatic, preferred, and strict settings produce the correct immutable wire configuration.
- Global and Japan selections produce their exact HTTPS/WSS endpoints.
- Float PCM encoding is little-endian and sample/frame boundaries are exact.
- Repeated cumulative prefixes send only their unsent suffix.
- Final and provisional token evolution produces the correct complete snapshot without duplicate
  tokens or control markers.
- Finalization sends remaining audio, 200 ms silence, finalize, empty frame, and waits for finished in
  order.
- Cancellation and timeout unblock pending receives and leave a clean next session.
- Server errors are categorized by `error_type`, retain `request_id`, and redact secrets/transcripts.

### Resolver and settings tests

- Soniox is compatible with each officially supported IME language and rejects invalid hints.
- Per-IME Japanese selection snapshots model, `ja`, strictness, and region for the full recording.
- Changing settings/IME/key after start does not mutate the active provider.
- Key save/read/remove uses `asr:soniox`; an empty save removes it.
- Soniox displays cloud credential states and never offers download/cache deletion.
- Legacy settings restore with a safe local fallback and no Soniox key.

### Lifecycle and scope tests

- Normal dictation streams and finalizes once through the existing AI/history/output path.
- Discard during partial/final processing closes the socket and produces no late output.
- No-audio and short-silence exits close an already-open socket.
- File, Meeting, dictionary training, and Local API resolve only the saved local fallback even when
  Soniox is the global dictation model.
- A Soniox failure never promotes a volatile partial to final output and surfaces one sanitized
  error.
- Old history entries decode without provider metadata; new Soniox entries round-trip their model
  metadata without credentials.

## Manual Acceptance

Using a private Soniox account and a signed Apple Silicon build:

- Save and verify a global-region key, assign Soniox to Japanese IME, and receive Japanese partials
  followed by one final paste.
- Switch Japanese to US before recording and confirm the configured language changes; switch during
  recording and confirm the current session remains Japanese.
- Exercise all three language modes with Japanese and mixed Japanese/English speech.
- Verify Double Shift toggle and push-to-talk both finalize the same Soniox session exactly once.
- Discard during live partials and during finalization; confirm no history, clipboard, or typed output.
- Remove/replace the key and verify the prior provider is not reused.
- Select Japan with a non-Japan key and confirm a sanitized configuration/authentication failure;
  then verify a region-enabled key if available.
- Confirm File Transcription, Meeting, dictionary training, and Local API stay on the displayed local
  fallback model.
- Inspect logs and backups and confirm that neither the key nor transcript content appears.

## Quality and Delivery

- Test-drive every behavior change with deterministic tests and injected transport events.
- Preserve session-ID checks across every await and WebSocket callback.
- Run strict SwiftLint, the complete Xcode test suite, the unsigned CI-equivalent suite, and the
  signed `./build.sh` workflow.
- Launch the exact signed Debug product and complete the manual acceptance cases that do not require
  a Japan-enabled account.

## Official Protocol References

- [WebSocket API](https://soniox.com/docs/api-reference/stt/websocket-api)
- [Realtime model lifecycle](https://soniox.com/docs/stt/models)
- [Supported languages](https://soniox.com/docs/stt/concepts/supported-languages)
- [Language hints](https://soniox.com/docs/stt/concepts/language-hints)
- [Language restrictions](https://soniox.com/docs/stt/concepts/language-restrictions)
- [Manual finalization](https://soniox.com/docs/stt/rt/manual-finalization)
- [Data residency](https://soniox.com/docs/data-residency)
- [Security and privacy](https://soniox.com/docs/security-and-privacy)

## Non-goals

- Soniox async/batch transcription.
- Soniox translation, diarization, or semantic endpoint detection.
- File, Meeting, dictionary-training, or Local API audio sent to Soniox.
- A hosted temporary-key broker or shared application credential.
- Automatic mid-recording reconnect or replay.
- A generic multi-vendor cloud-ASR framework.
- Automatic local fallback after a failed Soniox dictation.
- Sending MyFluidVoice custom-dictionary or vocabulary terms as Soniox context in the first release.

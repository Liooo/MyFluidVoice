# Soniox Integration Design

## Goal

Integrate the complete Soniox v5 streaming dictation implementation from
`feat/just-dictate-workflows` into the current MyFluidVoice `main` workspace,
while preserving the existing overlay-finalization fixes, Double-tap modifier
hotkeys, and the fork's disabled upstream updater.

## Scope

The integration includes the Soniox prerequisite workflow layers that the
provider depends on: recording-session identity and lifecycle, scoped ASR
provider selection, focus-aware output routing, Soniox region/language
configuration, credential verification and Keychain storage, WebSocket
transport and transcript reduction, credential/settings UI, backup/history
metadata, privacy copy, and their focused tests.

The source branch also contains unrelated workflow work and IME overlay badge
work. These are included because the Soniox implementation depends on the
shared session/routing changes, but current `main` overlay behavior and local
fork-specific changes remain authoritative when conflicts occur.

## Architecture and data flow

1. Settings persist Soniox endpoint region, language, model selection, and a
   verified API credential. Credentials are validated before being stored in
   Keychain and are represented in settings without exposing the secret.
2. A dictation start creates a recording-scoped session snapshot. The snapshot
   chooses Soniox only for explicitly routed dictation recordings; ordinary
   local transcription, dictionary capture, meetings, and other non-dictation
   paths remain local.
3. `SonioxProvider` owns one recording's WebSocket transport. Audio is sent as
   binary frames, end-of-audio is sent as the protocol text frame, and
   `SonioxTranscriptReducer` turns interim/final messages into stable output.
4. Stop, cancellation, timeout, transport failure, and finalization are
   session-scoped and idempotent. Final transcription completes before the
   existing paste/typing pipeline closes its overlay or emits output.
5. Settings UI exposes the provider, region/language, credential state, and
   dictation-scoped selection using the existing AI settings conventions.

## Conflict policy

- Keep current `main` changes for the dictation processing overlay lifecycle,
  including waiting for final output before hiding it.
- Keep the current Double-tap modifier implementation and both-sides checkbox;
  reconcile shared hotkey files instead of replacing them with the branch copy.
- Keep MyFluidVoice identity and upstream update disabling; do not restore
  upstream update checks, release buttons, or automatic installation.
- Preserve existing local model defaults and migrations unless the Soniox
  selection explicitly opts into cloud dictation.
- Preserve untracked user files such as `instruction.md`.

## Verification

- Run focused Soniox credential, provider, scope-routing, dictation lifecycle,
  and hotkey tests.
- Run the complete `Fluid` macOS test suite with code signing disabled when a
  development certificate is unavailable.
- Run `git diff --check` and a Debug build.
- Confirm the generated local Debug app launches, the Soniox settings are
  visible, the current primary shortcut remains Double-tap, and no upstream
  update prompt is enabled.


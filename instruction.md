# FluidVoice fork implementation instructions

## Goal

Fork the current `altic-dev/FluidVoice` and use it as the new application base. Preserve FluidVoice's recording, streaming, VAD, transcription finalization, overlay, typing, history, and AI post-processing architecture. Add the small set of workflows from Just Dictate that are still missing.

This is a port of user-facing behavior, not a request to copy Just Dictate's architecture wholesale. Follow FluidVoice's existing patterns and tests. Do not replace `ASRService`, `GlobalHotkeyManager`, `TypingService`, or the settings system when they can be extended.

FluidVoice repository:

- <https://github.com/altic-dev/FluidVoice>

Just Dictate reference repository:

- <https://github.com/Liooo/just-dictate>
- Local reference checkout, if available: `/Users/liooo/ghq/github.com/Liooo/just-dictate`

## Required features

### 1. IME-aware language and model selection

Detect the active macOS keyboard input source at the start of every dictation. Map the input source to a speech locale and allow a separate ASR model selection for each installed/selectable input source.

Examples:

- Apple/Google/ATOK Japanese input mode → `ja-JP`
- The Roman/English mode of the same IME → `en-US`
- US keyboard → `en-US`
- Chinese input sources → the appropriate `zh-CN` or `zh-TW`
- Korean input sources → `ko-KR`

Requirements:

- Enumerate installed selectable keyboard input sources in Settings.
- Show the input source's localized name and detected locale.
- Let the user select a FluidVoice `SpeechModel` independently for each input source.
- Persist assignments by stable input-source ID.
- At recording start, resolve the active input source and apply both its locale and model before ASR starts.
- If no assignment exists, fall back to FluidVoice's current global language/model settings.
- A missing, disabled, or renamed input source must not break existing settings or recording.
- Do not switch models in the middle of an active recording. A changed IME applies to the next recording.
- Respect model availability, OS/architecture restrictions, and download readiness already enforced by FluidVoice.

Use these Just Dictate files only as behavioral references:

- `just-dictate/IMEDetector.swift`
- `just-dictate/TranscriptionSettings.swift`
- the transcription-engine section in `just-dictate/SettingsView.swift`
- recognizer selection in `just-dictate/DictationManager.swift`

Likely FluidVoice integration points:

- `Sources/Fluid/Persistence/SettingsStore.swift`
- `Sources/Fluid/Services/ASRService.swift`
- `Sources/Fluid/UI/AISettingsView+SpeechRecognition.swift`
- the recording-start path in `Sources/Fluid/ContentView.swift`

Keep the resolved language and model together as one recording-session configuration so async work cannot observe a half-updated global setting.

### 2. Double-modifier hotkey, especially Double Shift

Add modifier-only double-tap shortcuts to FluidVoice's existing hotkey system. The primary requirement is Double Shift, but the implementation should work for the modifier-only keys already supported by FluidVoice where technically safe.

Requirements:

- The settings shortcut recorder must be able to capture and display `Double Shift` (and equivalent supported modifiers).
- Default double-tap interval: 300 ms. Keep it as one named constant.
- A double tap must require two clean presses of the same modifier.
- Any intervening ordinary key or additional modifier cancels the pending double tap.
- Key repeat and duplicate `flagsChanged` events must not trigger it.
- A single tap must not start dictation.
- Preserve FluidVoice's existing regular shortcuts and modifier-only hold/toggle/automatic behavior.
- Support these bindings:
  - Double-tap toggle: the second tap starts or stops dictation.
  - Double-tap push-to-talk: the second press starts dictation and releasing that second press finishes it.
- Reset pending tap state when shortcuts are disabled, recaptured, permissions change, the event tap is recreated, or the app changes mode.
- Do not swallow unrelated keyboard events.

Behavioral reference:

- `just-dictate/HotkeyManager.swift`
- hotkey types/storage in `just-dictate/Types.swift`
- shortcut capture in `just-dictate/SettingsView.swift`

Extend FluidVoice's existing state machine rather than adding a second global event tap:

- `Sources/Fluid/Services/GlobalHotkeyManager.swift`
- existing `ModifierOnlyShortcutFlagsDecision`
- existing hotkey settings and shortcut recorder

The double-tap decision logic must be a small pure/testable state transition separate from AppKit/CGEvent plumbing.

### 3. Escape and outside-click exit policies

When toggle-mode dictation is active, allow Escape and clicking outside the overlay/active target to have independently configurable actions:

- `Do nothing`
- `Close and discard`
- `Close and paste`

Requirements:

- Provide separate settings for Escape and outside click.
- Defaults should preserve Just Dictate behavior: `Close and paste` for both unless FluidVoice has a safer established default that must be retained for existing users.
- Apply these policies only to an active toggle-style dictation session. Push-to-talk release behavior must remain unchanged.
- `Discard` cancels ASR/post-processing and must never add history, modify the clipboard, or insert late final text.
- `Paste` follows FluidVoice's normal stop → final transcription → optional AI enhancement → typing pipeline exactly once.
- `Do nothing` leaves recording active.
- Ignore clicks inside FluidVoice's own recording overlay, menus, prompt picker, and settings windows.
- Deduplicate simultaneous triggers, such as Escape and an outside click arriving during finalization.
- Remove event monitors when recording ends or is cancelled.

Behavioral references:

- `ExitAction` and `ExitActionSettings` in `just-dictate/Types.swift`
- monitor and routing logic in `just-dictate/AppDelegate.swift`
- settings controls in `just-dictate/SettingsView.swift`

Use FluidVoice's existing stop/cancel entry points; do not create a parallel finalization path.

### 4. Recording start/end sound settings

Expose user-configurable recording feedback sounds.

Requirements:

- Master enable/disable control.
- Independent start-sound and end-sound selection.
- Include a `None` choice.
- Preview the selected sound from Settings.
- Start sound plays only after audio capture actually starts.
- End sound plays immediately when capture stops, before slow final transcription or AI post-processing.
- Cancel/discard should have a clear, consistent sound policy; prefer no normal completion sound if FluidVoice already distinguishes cancellation.
- Do not pause or block audio capture while playing feedback.

Just Dictate references:

- `SoundEffect` and `SoundSettings` in `just-dictate/Types.swift`
- sound settings UI in `just-dictate/SettingsView.swift`

FluidVoice already has `TranscriptionSoundPlayer`, `OnboardingSoundPlayer`, `transcriptionStartSound`, and related Settings UI. Audit what is already present first. Extend only missing behavior—most likely end-sound selection and any missing master toggle/preview. Do not duplicate the existing start-sound implementation.

### 5. Copy to clipboard only when no text input is focused

Add a setting equivalent to Just Dictate's `Copy transcription to clipboard when no input is focused`.

Requirements:

- Default enabled for new users unless FluidVoice migration compatibility requires otherwise.
- When a writable focused text element exists, use FluidVoice's normal direct insertion/typing path. Do not overwrite the clipboard just because this option is enabled.
- When there is no writable focused text element:
  - enabled → copy the final processed transcript to the clipboard;
  - disabled → leave the clipboard unchanged and surface the existing no-target feedback.
- Never copy a partial transcript.
- If AI post-processing succeeds, copy the processed text. If it fails and FluidVoice falls back, copy the raw fallback text.
- Preserve FluidVoice's clipboard restoration and external-change protection for temporary clipboard paste operations.
- Record accurate history/output metadata for `typed`, `copied`, `no target`, and `discarded` outcomes.

Just Dictate references:

- `ClipboardSettings` in `just-dictate/Types.swift`
- `just-dictate/KeyboardSimulator.swift`
- Advanced settings control in `just-dictate/SettingsView.swift`

FluidVoice integration points likely include:

- `Sources/Fluid/Services/TypingService.swift`
- final output routing in `Sources/Fluid/ContentView.swift`
- `Sources/Fluid/Persistence/SettingsStore.swift`
- the appropriate general/typing Settings view

## Explicit non-goals for the first implementation

- Do not port Just Dictate's recording or transcription session implementation.
- Do not port its WhisperKit recognizer.
- Do not add Kotoba Whisper yet.
- Do not replace FluidVoice's model downloader or provider architecture.
- Do not reimplement FluidVoice features such as history, VAD, overlay visualizer, AI enhancement, app-specific prompts, microphone selection, or clipboard restoration.
- Do not depend on Fluid Intelligence's private runtime. Cloud or OpenAI-compatible AI enhancement must continue to work without it.
- Do not redesign the whole Settings UI. Add controls using existing sections and visual conventions.

## Implementation order

1. Establish a clean FluidVoice fork and run its current test suite before changes.
2. Add pure data models/settings migrations and tests.
3. Implement IME detection and session configuration resolution.
4. Implement/test the double-modifier state machine, then connect it to the existing event tap.
5. Add/test Escape and outside-click policies using existing stop/cancel flows.
6. Audit and complete sound settings without duplicating existing FluidVoice code.
7. Add/test no-focused-input clipboard behavior in the final output router.
8. Run the full unit/integration suite and a signed macOS build.
9. Manually exercise the acceptance matrix below.

Use test-driven development for every behavior change. Before modifying concurrency or lifecycle code, reproduce the failure with a deterministic unit test where possible.

## Acceptance matrix

At minimum, verify these cases on Apple Silicon:

### IME/model

- Switch US → Japanese IME before recording; the configured locale/model changes.
- Switch IME during recording; the current session remains unchanged and the next session uses the new assignment.
- Assigned model is not downloaded; the user gets existing model-readiness UI/error and no broken recording state.
- Unknown input source uses global fallback.

### Hotkey

- Single Shift tap does nothing.
- Clean Double Shift toggles recording.
- Double Shift with second press held behaves as push-to-talk when configured that way.
- Shift, then another key, then Shift does not trigger.
- Left/right Shift behavior is deliberate and covered by tests.
- Existing chord and modifier-only shortcuts still work.

### Exit policy

- Escape and outside click each exercise all three actions.
- Clicking FluidVoice UI does not count as an outside click.
- Discard during partial/final/AI processing never produces late paste or clipboard output.
- Repeated exit events produce only one finalization/output.

### Sounds

- Disabled/None produces no sound.
- Start and end choices preview correctly.
- End feedback occurs when capture stops, not after model/LLM latency.

### Clipboard fallback

- Focused editable field receives text without persistent clipboard mutation.
- No focused field + setting enabled copies final text.
- No focused field + setting disabled leaves clipboard untouched.
- Failed AI enhancement uses the raw transcript consistently.

## Quality and delivery constraints

- Follow FluidVoice's formatting, actor/concurrency, logging, analytics, and settings migration patterns.
- Keep feature flags/settings backward-compatible. Existing FluidVoice users must retain their current hotkey/model behavior after upgrading.
- Avoid global mutable state for a recording's resolved IME/model configuration.
- All async callbacks must be scoped to a recording/session ID so cancelled or previous sessions cannot affect a new recording.
- Add focused tests for state machines and settings migrations, not timing-dependent sleeps.
- Run:

```sh
xcodebuild test -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS'
```

- Also produce and launch the signed development build using FluidVoice's documented `./build.sh` workflow.
- Before handing off, report changed files, test counts/results, build path, manual scenarios tested, and any known limitations.

## Licensing

Current FluidVoice is GPLv3. Keep required license notices and treat the fork as GPLv3-compatible. Do not copy code from a differently licensed source without checking compatibility. Just Dictate should primarily be used as a behavioral reference; where code is reused, preserve its license and attribution requirements.


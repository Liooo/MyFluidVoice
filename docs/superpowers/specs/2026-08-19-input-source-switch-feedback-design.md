# Input Source Switch Feedback

## Goal

Make live IME switching understandable while the speech recognizer changes
providers. The switch can take a few hundred milliseconds, so the overlay
should visibly communicate that the requested language is being prepared
instead of appearing unresponsive.

## Chosen approach

Use the existing input-source badge and the existing input-source switch task.
Add one presentation state to `NotchContentState`:

- `isInputSourceSwitching == true` while the current or queued ASR switch is
  being processed.
- The resolved target input-source badge is shown immediately.
- The badge is rendered in grayscale with reduced opacity.
- A compact `ProgressView` is shown beside it.
- The state remains active while a newer input-source change is queued.
- The state is cleared when the final switch succeeds, fails, recording ends,
  or the overlay is dismissed.

This keeps the feedback coupled to the same task that owns the actual ASR
transition. It avoids deriving UI state indirectly from provider readiness,
which can change for unrelated reasons.

## Alternatives considered

1. Add a presentation flag to the existing switch task (chosen). This is the
   smallest change, preserves the current target badge behavior, and naturally
   supports queued rapid switches.
2. Introduce a full switch state enum with target, progress, and error states.
   This would support richer messaging but adds states and UI that are not
   needed for the current feedback request.
3. Derive the spinner from `ASRService` readiness. This avoids a new state but
   cannot reliably distinguish an IME switch from normal model loading and can
   leave the badge and spinner out of sync.

## Data flow

1. `KeyboardInputSourceChangeMonitor` resolves a new input source.
2. `ContentView.handleInputSourceChange` resolves its speech configuration and
   updates the badge to the target input source.
3. Before starting `ASRService.switchRecordingSpeechConfiguration`, it sets
   `NotchContentState.isInputSourceSwitching` to `true`.
4. `ASRService` finalizes the old segment and prepares the new provider.
5. `ContentView` keeps the flag set if a queued target remains; otherwise it
   clears the flag after success or failure.
6. `BottomOverlayView` observes the shared state and renders the badge plus
   spinner only while the flag is set.

## UI behavior

- Normal badge rendering remains unchanged outside a switch.
- During a switch, the target badge uses grayscale and a subtle opacity
  reduction so it remains recognizable without suggesting the target is
  already ready.
- The spinner uses the existing compact `ProgressView` style used elsewhere in
  the overlay.
- No overlay text or layout-wide opacity is changed; transcription text and
  the rest of the overlay remain fully readable.
- The spinner is removed immediately when the final switch state is resolved.

## Error and lifecycle handling

- A failed switch clears the feedback state and leaves the current session
  usable with its existing configuration.
- A queued switch keeps feedback visible across the handoff between tasks.
- Stopping or cancelling recording clears the state so the next session cannot
  inherit a stale spinner.
- Overlay disappearance performs the same cleanup as the existing switch-task
  cancellation path.

## Verification

- Add or extend focused tests for the switch-state lifecycle and queued target
  behavior.
- Run `git diff --check`.
- Build the Debug macOS target.
- Run the focused input-source and live-switch tests, then the full test suite.
- Restart the Debug app and manually verify: English dictation, switch to
  Japanese, visible gray target badge plus spinner during preparation, and
  normal badge after Japanese recognition resumes.

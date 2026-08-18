# Dictation Overlay Processing Feedback Design

## Goal

Keep the dictation overlay visible after push-to-talk release until final transcription and output dispatch finish, while giving immediate visual feedback that recording has ended and the app is processing the captured speech.

## Context and root cause

The normal dictation stop path currently hides the overlay before `ASRService.stop()` completes. `ASRService.stop()` marks recording as no longer running before it performs the final transcription pass, so the user can see the overlay disappear while the final spoken words are still being recognized. The final text is still delivered later, which is why the input is correct despite the visual surprise.

AI-enabled and command/rewrite paths already keep the overlay alive through processing by using `MenuBarManager`'s processing state. The normal non-AI path needs to use the same lifecycle.

## Design

When the stop action begins for a normal dictation session:

1. Mark the overlay as processing before awaiting `ASRService.stop()`.
2. Show the existing transient `Transcribing` status and processing waveform/shimmer.
3. Keep the overlay visible while final ASR, formatting, optional output preparation, and output dispatch run.
4. Hide the overlay through the existing completion path after the final result is ready and output dispatch has been initiated.

The overlay's processing background changes from black to a subtle, neutral muted charcoal while `NotchContentState.isProcessing` is true. The same treatment applies to both the notch overlay and the bottom overlay. The color is intentionally low-contrast and mode-neutral so it communicates state without competing with the waveform or target-app icon.

The normal background returns when processing ends. Existing AI failure UI and other actionable persistent states keep their current behavior; they do not receive a separate long-lived state.

## Scope

- Modify the normal stop/processing lifecycle in `Sources/Fluid/ContentView.swift`.
- Update the notch overlay background in `Sources/Fluid/Views/NotchContentViews.swift`.
- Update the bottom overlay background in `Sources/Fluid/Views/BottomOverlayView.swift`.
- Reuse `NotchContentState.isProcessing`, existing `Transcribing` status text, and existing waveform processing visuals.
- Do not change ASR finalization, typing, hotkey semantics, persistence, or AI routing.

## Verification

- Run the focused existing integration test target/build available in the repository.
- Run a release-while-speaking manual smoke test with a sufficiently long utterance: the overlay must remain visible, switch to processing feedback immediately, and disappear only after the complete final text is ready for output.
- Check both notch and bottom overlay configurations.
- Confirm the existing untracked `instruction.md` remains untouched.

# Onboarding Overlay Dismissal Design

## Goal

Dismiss the dictation overlay automatically after a successful transcription in the onboarding sandbox, without typing into another app or persisting output.

## Design

Keep the existing onboarding sandbox routing and side-effect suppression unchanged. After the sandbox stores the final transcription and updates onboarding validation state, finish processing and hide the overlay through the existing lifecycle-aware completion path. The captured overlay lifecycle ID prevents an older transcription from hiding a newer overlay.

Empty transcription and cancellation behavior remain unchanged.

## Verification

- Build the app.
- Run the isolated onboarding preview.
- On the onboarding tryout step, hold the second Shift press and release it after speaking.
- Confirm the recognized result reaches onboarding and the overlay closes without Escape.
- Confirm no text is typed into another app and no clipboard/history side effects occur.

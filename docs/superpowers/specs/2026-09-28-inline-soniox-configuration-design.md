# Inline Soniox Configuration Design

## Goal

Make Soniox setup visually belong to the Soniox model row instead of appearing as a separate card beneath the complete model list.

## Interaction

- With no verified credential, the Soniox row shows `Configure`.
- Selecting `Configure` expands that same row downward.
- The expanded area contains the existing API key, Save & Verify, Remove Key, Language, Region, error, disclosure, and documentation-link controls.
- Successful verification changes the row action to `Activate` without selecting Soniox automatically.
- Activating Soniox changes the action to `Active`.
- Expanded model configuration sections are independent; opening one does not collapse another.

## Implementation

Keep the existing Soniox credential and activation state machine. Move the existing `sonioxSettingsSection` rendering from below the model list into the Soniox model card. Preserve `showSonioxSetup` as the expansion trigger, and keep the row tap gesture scoped to the row header so interaction with configuration controls does not retrigger model preview selection.

No credential storage, verification, activation, or default-setting behavior changes.

## Verification

- With Soniox unconfigured, `Configure` expands controls inside the Soniox row.
- Saving and verifying a valid key changes `Configure` to `Activate`.
- `Activate` selects Soniox; an unverified Soniox cannot be activated.
- Configuration controls remain usable without collapsing other expanded sections.
- Existing Soniox credential and model-action tests pass.

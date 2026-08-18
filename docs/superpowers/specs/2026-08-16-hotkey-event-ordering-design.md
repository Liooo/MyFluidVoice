# Modifier-Only Hotkey State Design

## Problem

Modifier-only shortcuts are recorded correctly but do not start dictation. This affects both a
single modifier chord such as `fn + Left Shift` and a gesture such as `Double Shift`; ordinary
keyboard shortcuts such as `Shift + Command + M` work.

Runtime modifier tracking currently refuses to add a newly observed modifier unless
`CGEventSource.keyState(.combinedSessionState, key:)` is already true. That query can lag the
current `flagsChanged` event. The resulting pressed-key set stays empty, so both the single-chord
and double-tap state machines ignore the event.

The behavior-only reference in `../just-dictate` does not query physical key state. Its
`HotkeyManager.handleFlagsChanged` treats the flags carried by the current event as the source of
truth for modifier-family transitions. FluidVoice also used this approach before the modifier
tracking helper was extracted in commit `7c9cbf2`.

## Goal

Make `fn + Left Shift`, `Double Shift`, and other modifier-only shortcuts start dictation reliably,
while preserving FluidVoice's side-specific key identity and duplicate-event protections.

## Chosen Design

Keep the global event tap at its established `.headInsertEventTap` placement. In
`PressedModifierKeyCodesDecision.synchronize`, use the current event's modifier flags to add a
newly observed physical key code and to remove a released modifier family. Consult the physical
key-state argument only for the genuinely ambiguous case where both left and right keys of the
same modifier family are already tracked.

This is a hybrid of the proven `just-dictate` behavior and FluidVoice's richer model:

- Aggregate event flags determine ordinary press and release transitions.
- The `flagsChanged` event key code preserves left/right identity.
- Physical key state disambiguates release only when a same-family sibling remains pressed.
- Existing single-modifier and double-tap decision machines remain unchanged.

## Alternatives Considered

- Use only aggregate flags, exactly as `just-dictate` does. This is simple, but it collapses left
  and right modifiers and would regress FluidVoice's side-specific shortcut support.
- Move the event tap to `.tailAppendEventTap`. A signed live build showed that this did not make
  `fn + Shift` or `Double Shift` work, and it changes event ordering for every keyboard and mouse
  shortcut without addressing the incorrect state transition rule.
- Add a second passive event tap to track modifier state. This adds synchronization and lifecycle
  complexity when the current event already contains the required transition data.

## Verification

- Add a regression test proving a first modifier press is tracked from event flags even when the
  physical-state query still reports false.
- Add runtime-sequence tests that feed lagging physical state through the real synchronizer and
  prove `fn + Left Shift` and `Double Shift` are recognized.
- Run all `HotkeyShortcutTests`, strict SwiftLint, and the full integration suite.
- Build and launch the signed Debug app, then verify both shortcuts reach `Dictate mode hotkey
  triggered` in the live log.

## Non-goals

- Copying `just-dictate` source or its simpler hotkey architecture.
- Changing shortcut persistence, activation modes, Accessibility permissions, or event
  consumption semantics.
- Changing the 300 ms double-tap window or relaxing same-side double-tap behavior.

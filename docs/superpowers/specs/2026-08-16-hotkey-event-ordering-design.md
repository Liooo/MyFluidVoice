# Hotkey Event Ordering Design

## Problem

Modifier-only shortcuts are recorded correctly but do not start dictation. Live diagnostics showed
that macOS delivers the configured `fn + Left Shift` sequence to `GlobalHotkeyManager`, while every
`ModifierOnlyShortcutFlagsDecision` remains `.ignore`.

The global event tap is installed at `.headInsertEventTap`. At that point the
`CGEventSource.keyState(.combinedSessionState, key:)` value used by
`PressedModifierKeyCodesDecision` can still describe the state before the current
`flagsChanged` transition. The recorder runs later in AppKit and sees the updated state, which is why
it can save a shortcut that the runtime never recognizes.

## Goal

Make modifier-only shortcuts, including `fn + Left Shift` and double-modifier gestures, use the
updated physical modifier state at runtime without rewriting the existing side-specific state
machine.

## Chosen Design

Keep the tap at `.cgSessionEventTap` and change only its placement from `.headInsertEventTap` to
`.tailAppendEventTap`. A small internal `HotkeyEventTapConfiguration` value will name this ordering
invariant and make it directly testable.

The existing event mask, active tap behavior, event consumption, permission flow, health checks,
and modifier decision types remain unchanged.

## Alternatives Considered

- Reconstruct press/release transitions from aggregate modifier flags at the head of the session.
  This makes duplicate events and simultaneous left/right modifiers ambiguous and would duplicate
  logic already covered by `PressedModifierKeyCodesDecision`.
- Add a second passive tap solely to track physical state. This introduces synchronization and
  lifecycle complexity without adding user-visible capability.

## Verification

- Add a focused test that fixes the event-tap placement at `.tailAppendEventTap`.
- Run all `HotkeyShortcutTests`.
- Run strict SwiftLint and an unsigned build.
- Build and launch the signed Debug app, then verify the currently configured `fn + Left Shift`
  shortcut reaches the dictation start path in the live log.

## Non-goals

- Changing the saved shortcut, activation mode, or Accessibility permissions.
- Redesigning modifier-only or double-tap gesture semantics.
- Changing keyboard event consumption outside the existing session tap.

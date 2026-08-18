# Modifier-Only Hotkey State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make modifier-only chords and double-modifier gestures recognize the current `flagsChanged` transition even when the Core Graphics physical-state query lags.

**Architecture:** Keep the existing session event tap and pure shortcut state machines. Correct only `PressedModifierKeyCodesDecision` so event flags drive ordinary transitions and physical state is reserved for same-family left/right ambiguity.

**Tech Stack:** Swift, AppKit/CoreGraphics, XCTest, Xcode 26.

## Global Constraints

- Preserve existing shortcut persistence and activation-mode behavior.
- Preserve left/right modifier tracking, duplicate-event handling, and event consumption.
- Keep the event tap at `.headInsertEventTap`.
- Do not change permissions, bundle identity, or unrelated recording lifecycle code.

---

### Task 1: Correct Runtime Modifier Synchronization

**Files:**
- Modify: `Sources/Fluid/Services/PressedModifierKeyCodesDecision.swift`
- Revert prior hypothesis: `Sources/Fluid/Services/GlobalHotkeyManager.swift`
- Test: `Tests/FluidDictationIntegrationTests/HotkeyShortcutTests.swift`

**Interfaces:**
- Consumes: `PressedModifierKeyCodesDecision.synchronize(previous:changedKeyCode:modifiers:changedKeyIsPhysicallyPressed:)`.
- Produces: a pressed-key set driven by the current event flags for ordinary transitions.

- [ ] **Step 1: Write failing regression tests**

Add tests that pass `changedKeyIsPhysicallyPressed: false` for the first `Shift` press and expect
`[56]`, then replay lagging physical state through the synchronizer plus the existing decision
machines for `fn + Left Shift` and `Double Shift`.

```swift
func testPressedModifierTrackingUsesEventFlagsWhenPhysicalStateLags() {
    let pressed = PressedModifierKeyCodesDecision.synchronize(
        previous: [],
        changedKeyCode: 56,
        modifiers: .shift,
        changedKeyIsPhysicallyPressed: false
    )

    XCTAssertEqual(pressed, [56])
}
```

Use the same `synchronize` call before every event passed to
`ModifierOnlyShortcutFlagsDecision`/`DoubleModifierTapDecision`, always supplying false for the
physical-state argument. Assert the chord reaches `.start`/a clean `.finish`, and the double tap
reaches `.secondPress`/`.secondRelease`.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
xcodebuild test -project Fluid.xcodeproj -scheme Fluid \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:FluidDictationIntegrationTests/HotkeyShortcutTests \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: the new lagging-physical-state assertions fail because the first modifier key is not
inserted.

- [ ] **Step 3: Implement the minimal transition fix**

When the current event flags include the changed modifier family and the changed key code is not
already tracked, insert that key code without requiring the lagging physical-state query. Retain
the physical-state query only in the existing same-family sibling-release branch. Restore
`CGEvent.tapCreate` to `.headInsertEventTap` and remove the disproven placement test/helper.

```swift
if synchronized.contains(changedKeyCode) {
    let siblingIsTracked = changedGroup.1.contains { keyCode in
        keyCode != changedKeyCode && synchronized.contains(keyCode)
    }
    if siblingIsTracked, !changedKeyIsPhysicallyPressed {
        synchronized.remove(changedKeyCode)
    }
} else {
    synchronized.insert(changedKeyCode)
}
```

- [ ] **Step 4: Run focused and repository verification**

Run:

```bash
xcodebuild test -project Fluid.xcodeproj -scheme Fluid \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:FluidDictationIntegrationTests/HotkeyShortcutTests \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
swiftlint lint --strict
xcodebuild test -project Fluid.xcodeproj -scheme Fluid \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
./build.sh
```

Expected: focused and full tests pass, strict lint passes, and `build.sh` completes its signed
build plus deep signature verification.

- [ ] **Step 5: Verify both live shortcuts and commit**

Launch `DerivedData/Build/Products/Debug/MyFluidVoice Debug.app`. Configure and press
`fn + Left Shift`, then `Double Shift`, and confirm each reaches `Dictate mode hotkey triggered` in
`~/Library/Logs/Fluid/Fluid.log`.

```bash
git add Sources/Fluid/Services/PressedModifierKeyCodesDecision.swift \
  Sources/Fluid/Services/GlobalHotkeyManager.swift \
  Tests/FluidDictationIntegrationTests/HotkeyShortcutTests.swift \
  docs/superpowers/specs/2026-08-16-hotkey-event-ordering-design.md \
  docs/superpowers/plans/2026-08-16-hotkey-event-ordering.md
git commit -m 'fix: track modifier hotkey transitions from event flags'
```

# Hotkey Event Ordering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make recorded modifier-only shortcuts start dictation by reading physical modifier state after the current session event is applied.

**Architecture:** Keep the existing session-level active event tap and modifier state machine. Name the required tail placement as an internal configuration invariant, use it when creating the tap, and lock it with a focused test.

**Tech Stack:** Swift, AppKit/CoreGraphics, XCTest, Xcode 26.

## Global Constraints

- Preserve existing shortcut persistence and activation-mode behavior.
- Preserve left/right modifier tracking, duplicate-event handling, and event consumption.
- Do not change permissions, bundle identity, or unrelated recording lifecycle code.

---

### Task 1: Correct Global Hotkey Event Ordering

**Files:**
- Modify: `Sources/Fluid/Services/GlobalHotkeyManager.swift`
- Test: `Tests/FluidDictationIntegrationTests/HotkeyShortcutTests.swift`

**Interfaces:**
- Consumes: `CGEventTapPlacement` and the existing `PressedModifierKeyCodesDecision` runtime path.
- Produces: internal `HotkeyEventTapConfiguration.placement: CGEventTapPlacement` fixed to `.tailAppendEventTap`.

- [ ] **Step 1: Write the failing placement invariant test**

```swift
func testGlobalHotkeyTapRunsAfterSessionModifierStateUpdates() {
    XCTAssertEqual(
        HotkeyEventTapConfiguration.placement.rawValue,
        CGEventTapPlacement.tailAppendEventTap.rawValue
    )
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
xcodebuild test -project Fluid.xcodeproj -scheme Fluid \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:FluidDictationIntegrationTests/HotkeyShortcutTests \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: compilation fails because `HotkeyEventTapConfiguration` does not exist.

- [ ] **Step 3: Add and use the minimal configuration invariant**

```swift
nonisolated enum HotkeyEventTapConfiguration {
    static let placement = CGEventTapPlacement.tailAppendEventTap
}
```

Change `CGEvent.tapCreate` to pass:

```swift
place: HotkeyEventTapConfiguration.placement
```

- [ ] **Step 4: Run focused and repository verification**

Run the focused test command from Step 2, then:

```bash
swiftlint lint --strict
xcodebuild build -project Fluid.xcodeproj -scheme Fluid \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
FLUIDVOICE_DEVELOPMENT_TEAM=X95NPTT7A8 ./build.sh
```

Expected: focused tests and lint pass, unsigned and signed builds succeed, and strict signature
verification performed by `build.sh` passes.

- [ ] **Step 5: Verify the live shortcut and commit**

Launch `DerivedData/Build/Products/Debug/MyFluidVoice Debug.app`, press the configured
`fn + Left Shift`, and confirm `Dictate mode hotkey triggered` appears in
`~/Library/Logs/Fluid/Fluid.log`.

```bash
git add Sources/Fluid/Services/GlobalHotkeyManager.swift \
  Tests/FluidDictationIntegrationTests/HotkeyShortcutTests.swift
git commit -m 'fix: observe updated modifier state for hotkeys'
```

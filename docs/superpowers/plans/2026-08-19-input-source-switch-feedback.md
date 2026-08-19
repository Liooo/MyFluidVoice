# Input Source Switch Feedback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the resolved target IME in a subdued state with a compact spinner while its live ASR configuration is being prepared.

**Architecture:** Reuse the existing `ContentView` input-source switch task and pending-configuration queue. Publish one lifecycle flag from `NotchContentState`; `BottomOverlayView` observes it and changes only the IME badge plus its adjacent loading indicator. The flag remains active across queued switches and is cleared on final completion, failure, or recording cleanup.

**Tech Stack:** Swift, SwiftUI, Combine, XCTest, macOS AppKit/Carbon TIS APIs.

## Global Constraints

- Keep the existing target IME badge, transcription text, waveform, and overlay behavior unchanged outside an active switch.
- Do not apply opacity or grayscale to the whole overlay; only the IME badge is visually subdued.
- Keep the spinner visible until the last queued ASR switch resolves.
- Preserve all existing uncommitted implementation changes and commit only feature files when committing.

---

### Task 1: Add the published switch-feedback state

**Files:**
- Modify: `Sources/Fluid/Views/NotchContentViews.swift:107-145,311-315`
- Test: `Tests/FluidDictationIntegrationTests/DictationE2ETests.swift` in `LiveInputSourceSwitchTests`

**Interfaces:** Add `NotchContentState.isInputSourceSwitching: Bool`; make `clearRecordingPresentationContext()` reset it.

- [ ] **Step 1: Add the failing lifecycle test**

```swift
    func testInputSourceSwitchingPresentationStateCanStartAndReset() {
        let state = NotchContentState.shared
        let originalValue = state.isInputSourceSwitching
        defer { state.isInputSourceSwitching = originalValue }

        state.isInputSourceSwitching = false
        XCTAssertFalse(state.isInputSourceSwitching)
        state.isInputSourceSwitching = true
        XCTAssertTrue(state.isInputSourceSwitching)
        state.clearRecordingPresentationContext()
        XCTAssertFalse(state.isInputSourceSwitching)
    }
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
xcodebuild test -quiet -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS' -derivedDataPath /Users/liooo/Library/Developer/Xcode/DerivedData/Fluid-cqdugkxnrnbyzmabmaxrabxyucib -only-testing:FluidDictationIntegrationTests/LiveInputSourceSwitchTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Expected: compile failure because `isInputSourceSwitching` is not defined.

- [ ] **Step 3: Implement the state and cleanup reset**

Add beside `recordingInputSourceBadge`:

```swift
    /// True while a live input-source change is preparing its new speech provider.
    @Published var isInputSourceSwitching: Bool = false
```

Update cleanup to:

```swift
    func clearRecordingPresentationContext() {
        self.targetAppIcon = nil
        self.recordingInputSourceBadge = nil
        self.isInputSourceSwitching = false
    }
```

- [ ] **Step 4: Run the focused test and commit**

Run the command from Step 2; expected result is PASS. Then run `git diff --check` and commit only:

```bash
git add Sources/Fluid/Views/NotchContentViews.swift Tests/FluidDictationIntegrationTests/DictationE2ETests.swift
git commit -m "feat: track live input source switch feedback"
```

### Task 2: Drive the feedback state from the switch lifecycle

**Files:**
- Modify: `Sources/Fluid/ContentView.swift:1917-2015,4510-4525,4600-4615`
- Test: `Tests/FluidDictationIntegrationTests/DictationE2ETests.swift` in `LiveInputSourceSwitchTests`

**Interfaces:** Consume Task 1's published flag; reuse `inputSourceSwitchTask` and `inputSourceSwitchQueue` without adding another queue.

- [ ] **Step 1: Add the queued-switch assertion**

In `testRapidInputSourceSwitchesKeepTheLatestPendingConfiguration`, replace the existing `var pending` and two `pending.replace` lines with this block. It models the UI state staying active while the newest queued configuration is waiting:

```swift
        let presentationState = NotchContentState.shared
        let originalPresentationState = presentationState.isInputSourceSwitching
        defer { presentationState.isInputSourceSwitching = originalPresentationState }

        presentationState.isInputSourceSwitching = true
        pending.replace(with: english)
        pending.replace(with: japanese)

        XCTAssertTrue(presentationState.isInputSourceSwitching)
        XCTAssertEqual(pending.take(), japanese)

        presentationState.isInputSourceSwitching = false
        XCTAssertFalse(presentationState.isInputSourceSwitching)
```

- [ ] **Step 2: Run the focused live-switch tests**

Run:

```bash
xcodebuild test -quiet -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS' -derivedDataPath /Users/liooo/Library/Developer/Xcode/DerivedData/Fluid-cqdugkxnrnbyzmabmaxrabxyucib -only-testing:FluidDictationIntegrationTests/LiveInputSourceSwitchTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Expected: PASS.

- [ ] **Step 3: Activate feedback for first and queued changes**

In `handleInputSourceChange`, immediately before each `captureRecordingInputSourceBadge()` that represents a real configuration change, set:

```swift
NotchContentState.shared.isInputSourceSwitching = true
```

This applies both to the `inputSourceSwitchTask != nil` queue branch and to the first-switch branch. Leave the same-configuration guard unchanged so duplicate notifications do not show a spinner.

- [ ] **Step 4: Clear only at the final switch boundary**

In `startInputSourceSwitch`, after `self.inputSourceSwitchTask = nil`:

```swift
guard didSwitch else {
    _ = self.inputSourceSwitchQueue.take()
    NotchContentState.shared.isInputSourceSwitching = false
    return
}
```

If no valid pending configuration remains, set the flag to `false` before returning. If a pending configuration remains, keep it `true` and recursively start the next switch. This ensures rapid switches do not briefly hide the spinner.

- [ ] **Step 5: Clear cancellation state**

In the existing `onDisappear` cleanup beside `inputSourceSwitchTask?.cancel()`, add:

```swift
NotchContentState.shared.isInputSourceSwitching = false
```

Normal recording completion is covered by `clearRecordingPresentationContext()`.

- [ ] **Step 6: Verify and commit**

Run:

```bash
xcodebuild test -quiet -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS' -derivedDataPath /Users/liooo/Library/Developer/Xcode/DerivedData/Fluid-cqdugkxnrnbyzmabmaxrabxyucib -only-testing:FluidDictationIntegrationTests/LiveInputSourceSwitchTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
git diff --check
```

Expected: PASS and no whitespace errors. Commit only the lifecycle files:

```bash
git add Sources/Fluid/ContentView.swift Sources/Fluid/Views/NotchContentViews.swift Tests/FluidDictationIntegrationTests/DictationE2ETests.swift
git commit -m "feat: show input source switch progress state"
```

### Task 3: Render the target badge and spinner

**Files:**
- Modify: `Sources/Fluid/Views/BottomOverlayView.swift:2164-2184,2954-2970`

**Interfaces:** Consume `contentState.recordingInputSourceBadge` and `contentState.isInputSourceSwitching`; add no public API.

- [ ] **Step 1: Replace the badge row block**

Use this existing-row replacement:

```swift
                    if let inputSourceBadge, !inputSourceBadge.isEmpty {
                        HStack(spacing: max(2, self.layout.hPadding / 4)) {
                            self.inputSourceBadgeView(inputSourceBadge)
                                .grayscale(self.contentState.isInputSourceSwitching ? 1 : 0)
                                .opacity(self.contentState.isInputSourceSwitching ? 0.58 : 1)

                            if self.contentState.isInputSourceSwitching {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(.white.opacity(0.72))
                                    .accessibilityLabel("Switching input source")
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.leading, self.layout.hPadding / 3)
                    }
```

Only the badge receives grayscale/opacity; the transcription content and the spinner remain fully visible.

- [ ] **Step 2: Build and commit**

Run:

```bash
xcodebuild -quiet -project Fluid.xcodeproj -scheme Fluid -configuration Debug -destination 'platform=macOS' -derivedDataPath /Users/liooo/Library/Developer/Xcode/DerivedData/Fluid-cqdugkxnrnbyzmabmaxrabxyucib build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Expected: exit code 0; existing deprecation/framework-symlink warnings are acceptable. Then commit:

```bash
git add Sources/Fluid/Views/BottomOverlayView.swift
git commit -m "feat: show input source switch spinner"
```

### Task 4: Full verification and restart

**Files:** Verify the four files changed above; do not add generated files.

- [ ] **Step 1: Run focused routing and live-switch tests**

```bash
xcodebuild test -quiet -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS' -derivedDataPath /Users/liooo/Library/Developer/Xcode/DerivedData/Fluid-cqdugkxnrnbyzmabmaxrabxyucib -only-testing:FluidDictationIntegrationTests/KeyboardInputSourceRoutingTests -only-testing:FluidDictationIntegrationTests/LiveInputSourceSwitchTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Expected: exit code 0.

- [ ] **Step 2: Run the complete test suite**

```bash
xcodebuild test -quiet -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS' -derivedDataPath /Users/liooo/Library/Developer/Xcode/DerivedData/Fluid-cqdugkxnrnbyzmabmaxrabxyucib CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Expected: exit code 0.

- [ ] **Step 3: Check state and restart the exact Debug app**

Run `git diff --check` and `git status --short`; only the existing feature files may remain modified. Find the exact Debug PID with:

```bash
ps ax -o pid=,lstart=,command= | rg '/Build/Products/Debug/MyFluidVoice Debug\\.app/Contents/MacOS/MyFluidVoice' | rg -v 'rg '
```

Kill only that explicit PID, then run:

```bash
open -n '/Users/liooo/Library/Developer/Xcode/DerivedData/Fluid-cqdugkxnrnbyzmabmaxrabxyucib/Build/Products/Debug/MyFluidVoice Debug.app'
```

Verify the resulting process is that exact path and startup does not begin a recording session.

- [ ] **Step 4: Manually verify the feedback**

Start English dictation, switch to Japanese with the standard macOS shortcut, and confirm the Japanese badge appears gray with a spinner during ASR preparation. Confirm transcription text stays readable, the spinner disappears after the final switch, and Japanese text appends after the existing English text.

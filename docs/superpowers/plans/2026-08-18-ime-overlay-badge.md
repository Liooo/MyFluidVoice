# IME Overlay Badge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the active dictation session's IME icon beside the target application's icon in the bottom dictation overlay, with deterministic flag/language fallbacks.

**Architecture:** Keep `KeyboardInputSourceSnapshot` unchanged as the Sendable routing value. Add a presentation-only resolver that reads the TIS native icon when available and derives a flag or language label from the already-resolved locale. Capture that presentation value at dictation start into `NotchContentState`, render it beside `targetAppIcon`, and clear it with the existing overlay teardown.

**Tech Stack:** Swift 6, SwiftUI, AppKit/Carbon TIS, XCTest, Xcode macOS target.

## Global Constraints

- The badge is informational only and must not change model selection, locale binding, focus restoration, or typing behavior.
- Capture the badge at recording start and keep it fixed for that session; do not live-update it during a recording.
- Prefer the native `kTISPropertyIconRef` icon; fall back to locale flag, then uppercase language code, then no badge.
- Do not persist the badge or add a settings toggle.
- Keep existing target-app icon sizing and waveform placement stable.
- Run focused tests, strict SwiftLint, `git diff --check`, and a signed macOS build before claiming completion.

---

### Task 1: Add presentation-only IME badge resolution

**Files:**
- Modify: `Sources/Fluid/Services/KeyboardInputSourceService.swift`
- Test: `Tests/FluidDictationIntegrationTests/SonioxScopeRoutingTests.swift` (existing registered test file; add a focused pure test section)

**Interfaces:**
- Produces `KeyboardInputSourceBadge: @unchecked Sendable` with `sourceID: String`, `localeIdentifier: String`, `nativeIcon: NSImage?`, `fallbackText: String?`, and `isEmpty`.
- Produces `KeyboardInputSourceService.badge(for:nativeIcon:) -> KeyboardInputSourceBadge?` for pure/injected tests and `currentInputSourceBadge() -> KeyboardInputSourceBadge?` for production capture.
- Produces pure helpers `KeyboardInputSourceBadgeFormatter.flag(for:)` and `languageCode(for:)` for deterministic tests.

- [ ] **Step 1: Write failing formatter tests**

Add tests that assert:

```swift
XCTAssertEqual(KeyboardInputSourceBadgeFormatter.flag(for: "ja-JP"), "🇯🇵")
XCTAssertEqual(KeyboardInputSourceBadgeFormatter.flag(for: "en-US"), "🇺🇸")
XCTAssertEqual(KeyboardInputSourceBadgeFormatter.flag(for: "zh-CN"), "🇨🇳")
XCTAssertEqual(KeyboardInputSourceBadgeFormatter.flag(for: "zh-TW"), "🇹🇼")
XCTAssertEqual(KeyboardInputSourceBadgeFormatter.flag(for: "ko-KR"), "🇰🇷")
XCTAssertNil(KeyboardInputSourceBadgeFormatter.flag(for: "ja"))
XCTAssertEqual(KeyboardInputSourceBadgeFormatter.languageCode(for: "ja"), "JA")
XCTAssertEqual(KeyboardInputSourceBadgeFormatter.languageCode(for: "en-GB"), "EN")
XCTAssertNil(KeyboardInputSourceBadgeFormatter.languageCode(for: ""))
```

Also assert that a snapshot with no native icon still yields the expected fallback without changing its ID, name, or language list, and that an injected native icon takes precedence over the fallback text.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
xcodebuild test -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS' \
  -only-testing:FluidDictationIntegrationTests/SonioxScopeRoutingTests \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath /tmp/myfluidvoice-ime-badge-red
```

Expected: compile failure because `KeyboardInputSourceBadgeFormatter` and `KeyboardInputSourceService.badge(for:)` do not exist.

- [ ] **Step 3: Implement the presentation value and resolver**

Add AppKit import and the following behavior to `KeyboardInputSourceService.swift`:

```swift
nonisolated struct KeyboardInputSourceBadge: @unchecked Sendable {
    let sourceID: String
    let localeIdentifier: String
    let nativeIcon: NSImage?
    let fallbackText: String?

    var isEmpty: Bool { self.nativeIcon == nil && self.fallbackText == nil }
}

nonisolated enum KeyboardInputSourceBadgeFormatter {
    static func flag(for localeIdentifier: String) -> String? {
        guard let region = Locale(identifier: localeIdentifier).region?.identifier,
              region.count == 2,
              region.unicodeScalars.allSatisfy({ $0.value >= 65 && $0.value <= 90 })
        else { return nil }
        return String(region.unicodeScalars.map { UnicodeScalar($0.value + 0x1F1A5)! })
    }

    static func languageCode(for localeIdentifier: String) -> String? {
        let language = Locale(identifier: localeIdentifier).language?.languageCode?.identifier
        guard let language, language.count >= 2 else { return nil }
        return language.uppercased()
    }
}
```

`currentInputSourceBadge()` must read the current TIS source and snapshot, then call `badge(for:nativeIcon:)`. The injected `badge(for:nativeIcon:)` must resolve the locale using `KeyboardInputSourceLocaleResolver.localeIdentifier(for:)`, preserve the source ID/locale, and choose the injected icon first, then the formatter's flag or language code. The production helper reads `kTISPropertyIconRef` from the current matching TIS source by ID and converts it with `NSImage(iconRef:label:)` when non-nil. Return `nil` only when the source is unavailable and no fallback locale can be derived. Keep native icon conversion isolated in a private helper so deprecated Carbon/AppKit bridging is limited to one line and can fail safely.

- [ ] **Step 4: Run tests and verify GREEN**

Run the same `xcodebuild test` command from Step 2. Expected: all `SonioxScopeRoutingTests` pass, including the new formatter and fallback assertions.

- [ ] **Step 5: Run focused lint and commit**

```bash
swiftlint lint --strict Sources/Fluid/Services/KeyboardInputSourceService.swift Tests/FluidDictationIntegrationTests/SonioxScopeRoutingTests.swift
git diff --check
git add Sources/Fluid/Services/KeyboardInputSourceService.swift Tests/FluidDictationIntegrationTests/SonioxScopeRoutingTests.swift
git commit -m "feat: resolve IME overlay badge"
```

Expected: zero lint violations and a commit containing only the resolver and tests.

### Task 2: Capture and clear the badge with overlay session state

**Files:**
- Modify: `Sources/Fluid/Views/NotchContentViews.swift`
- Modify: `Sources/Fluid/Views/BottomOverlayView.swift`
- Modify: `Sources/Fluid/ContentView.swift`
- Test: `Tests/FluidDictationIntegrationTests/DictationE2ETests.swift` (existing registered suite)

**Interfaces:**
- `NotchContentState.recordingInputSourceBadge: KeyboardInputSourceBadge?` is the presentation state consumed by the overlay.
- `ContentView.captureRecordingInputSourceBadge()` captures `KeyboardInputSourceService.currentInputSource()` and stores its badge before the dictation session is created.

- [ ] **Step 1: Add lifecycle RED tests**

Add a state-level test helper on `NotchContentState` that clears the recording presentation context. Set a badge and target icon, invoke the helper, and assert both published values are nil. Add a pure capture test that creates a badge from a fixed `KeyboardInputSourceSnapshot`, changes the separately supplied current snapshot afterward, and asserts the stored badge remains equal to the first value; this verifies the snapshot contract without making Carbon calls in tests.

- [ ] **Step 2: Run the targeted tests and verify RED**

```bash
xcodebuild test -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS' \
  -only-testing:FluidDictationIntegrationTests/DictationE2ETests \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath /tmp/myfluidvoice-ime-badge-state-red
```

Expected: compile failures for the missing published state and capture helper.

- [ ] **Step 3: Implement state capture and teardown**

Add the published badge property next to `targetAppIcon` and a `clearRecordingPresentationContext()` method that clears both `targetAppIcon` and `recordingInputSourceBadge`. In `ContentView`, add `captureRecordingInputSourceBadge()` and call it immediately after `captureRecordingContext()` and before `beginDictationSession` in both normal dictation start paths (`startRecording` and `beginDictationRecording`). Do not call it from command/edit-only starts. In `BottomOverlayView` teardown paths that currently assign `targetAppIcon = nil`, call `clearRecordingPresentationContext()` instead. Preserve the existing target icon behavior and do not change `ActiveAppMonitor`.

- [ ] **Step 4: Run targeted tests and verify GREEN**

Run the same command from Step 2. Expected: the dictation state tests pass and existing `DictationE2ETests` remain green.

- [ ] **Step 5: Commit the lifecycle changes**

```bash
git diff --check
git add Sources/Fluid/Views/NotchContentViews.swift Sources/Fluid/Views/BottomOverlayView.swift Sources/Fluid/ContentView.swift Tests/FluidDictationIntegrationTests/DictationE2ETests.swift
git commit -m "feat: snapshot IME badge for dictation sessions"
```

### Task 3: Render the badge beside the target app icon

**Files:**
- Modify: `Sources/Fluid/Views/BottomOverlayView.swift`
- Test: `Tests/FluidDictationIntegrationTests/DictationE2ETests.swift`

**Interfaces:**
- Consumes `NotchContentState.recordingInputSourceBadge` from Task 2.
- Produces a compact SwiftUI badge without changing the existing target icon or waveform interfaces.

- [ ] **Step 1: Add presentation tests for native/fallback precedence**

Extend the pure badge tests to assert that a non-nil native icon is rendered through the native branch, while a nil native icon renders the fallback label. Assert that an empty badge renders no badge.

- [ ] **Step 2: Implement the overlay row**

Extract the existing target-icon-only `VStack` in `BottomOverlayView` into a local `@ViewBuilder` computed property named `targetAppIconView`, then wrap it in a compact `HStack`:

```swift
HStack(spacing: 3) {
    targetAppIconView
    if let badge = self.contentState.recordingInputSourceBadge, !badge.isEmpty {
        if let icon = badge.nativeIcon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: max(self.layout.iconSize * 0.62, 9), height: max(self.layout.iconSize * 0.62, 9))
                .clipShape(RoundedRectangle(cornerRadius: 2))
        } else if let fallbackText = badge.fallbackText {
            Text(fallbackText)
                .font(.system(size: max(self.layout.iconSize * 0.48, 8), weight: .semibold))
                .frame(minWidth: max(self.layout.iconSize * 0.62, 11), minHeight: max(self.layout.iconSize * 0.62, 11))
                .background(.thinMaterial, in: Capsule())
        }
    }
}
```

The `targetAppIconView` property must contain the current loading indicator, image, fallback circle, frame, and opacity expression unchanged. Keep the outer group aligned to the original icon size so the waveform does not jump when the badge appears. Hide the entire icon/badge group only under the same conditions as the existing target icon view.

- [ ] **Step 3: Run overlay and integration tests**

```bash
xcodebuild test -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS' \
  -only-testing:FluidDictationIntegrationTests/DictationE2ETests \
  -only-testing:FluidDictationIntegrationTests/SonioxScopeRoutingTests \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath /tmp/myfluidvoice-ime-badge-green
```

Expected: all selected tests pass with no new UI-state failures.

- [ ] **Step 4: Run formatting/lint and commit**

```bash
swiftformat --lint Sources/Fluid/Services/KeyboardInputSourceService.swift Sources/Fluid/Views/NotchContentViews.swift Sources/Fluid/Views/BottomOverlayView.swift Sources/Fluid/ContentView.swift Tests/FluidDictationIntegrationTests/DictationE2ETests.swift Tests/FluidDictationIntegrationTests/SonioxScopeRoutingTests.swift
swiftlint lint --strict Sources/Fluid/Services/KeyboardInputSourceService.swift Sources/Fluid/Views/NotchContentViews.swift Sources/Fluid/Views/BottomOverlayView.swift Sources/Fluid/ContentView.swift Tests/FluidDictationIntegrationTests/DictationE2ETests.swift Tests/FluidDictationIntegrationTests/SonioxScopeRoutingTests.swift
git diff --check
git add Sources/Fluid/Services/KeyboardInputSourceService.swift Sources/Fluid/Views/NotchContentViews.swift Sources/Fluid/Views/BottomOverlayView.swift Sources/Fluid/ContentView.swift Tests/FluidDictationIntegrationTests/DictationE2ETests.swift Tests/FluidDictationIntegrationTests/SonioxScopeRoutingTests.swift
git commit -m "feat: show IME badge in dictation overlay"
```

### Task 4: Final verification and signed app handoff

**Files:**
- Verify: all modified files from Tasks 1–3
- Build product: `DerivedData/Build/Products/Debug/MyFluidVoice Debug.app`

- [ ] **Step 1: Run the focused regression suite**

```bash
xcodebuild test -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS' \
  -only-testing:FluidDictationIntegrationTests/DictationE2ETests \
  -only-testing:FluidDictationIntegrationTests/SonioxScopeRoutingTests \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath /tmp/myfluidvoice-ime-badge-final-tests
```

Expected: zero failures and zero unexpected skips.

- [ ] **Step 2: Run strict lint and repository checks**

```bash
swiftlint lint --strict Sources/Fluid/Services/KeyboardInputSourceService.swift Sources/Fluid/Views/NotchContentViews.swift Sources/Fluid/Views/BottomOverlayView.swift Sources/Fluid/ContentView.swift Tests/FluidDictationIntegrationTests/DictationE2ETests.swift Tests/FluidDictationIntegrationTests/SonioxScopeRoutingTests.swift
git diff --check
git status --short
```

Expected: zero violations, no whitespace errors, and only intentional feature changes.

- [ ] **Step 3: Build and sign the app**

```bash
./build.sh public
codesign --verify --deep --strict 'DerivedData/Build/Products/Debug/MyFluidVoice Debug.app'
```

Expected: `BUILD SUCCEEDED` and `codesign` exits 0.

- [ ] **Step 4: Launch the exact product and smoke-test**

Quit any older process using the exact product path, launch the freshly built app, choose a Japanese IME and an English IME in turn, and start dictation in an external text field. Verify the target app icon remains unchanged, the IME icon/flag appears directly beside it, the badge remains fixed through the session, and the next session updates it.

- [ ] **Step 5: Commit the final verification note**

```bash
git status --short
git log -4 --oneline
```

Leave the worktree clean and report the test count, build result, signed app path, and any platform limitation observed for native IME icons.

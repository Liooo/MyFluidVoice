# Soniox Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate the Soniox v5 streaming dictation workflow and its prerequisites from `feat/just-dictate-workflows` through `091976e` into MyFluidVoice `main`, preserving current fork-specific behavior.

**Architecture:** Merge the coherent workflow history rather than cherry-picking isolated Soniox commits. Resolve shared files with current MyFluidVoice behavior authoritative for overlay finalization, Double-tap shortcuts, and updater disabling; retain the branch's session-scoped ASR, Soniox provider, credential, routing, and settings layers. Validate the merged app with focused and full macOS tests before launching the local Debug app.

**Tech Stack:** Swift, SwiftUI, AppKit, Foundation `URLSessionWebSocketTask`, Xcode, XCTest, macOS Keychain.

## Global Constraints

- Preserve the current Double-tap modifier hotkey and left/right modifier checkbox behavior.
- Preserve overlay visibility until final transcription output is ready.
- Keep upstream update checks, release update buttons, and automatic upstream installation disabled.
- Keep local model defaults and non-dictation transcription routes local unless explicitly configured for Soniox dictation.
- Preserve untracked user files, including `instruction.md`, unless the merge proves them byte-identical to the branch copy.
- Do not add an SPM dependency for Soniox; use Foundation WebSocket APIs.
- Run tests with `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` when signing credentials are unavailable.

---

### Task 1: Checkpoint and prepare the integration

**Files:**
- Modify: current working tree only; checkpoint all existing WIP changes in a recoverable local commit.

**Interfaces:**
- Produces: a clean `main` worktree whose `HEAD` contains the existing Double-tap, overlay, updater, and user-file changes.

- [ ] **Step 1: Record the current status and exact app process.**

```bash
git status --short
git diff --check
git log --oneline --max-count=5
ps ax -o pid=,ppid=,state=,args= | rg '/FluidVoice Debug.app/Contents/MacOS/FluidVoice Debug' || true
```

Expected: only the known WIP files are modified/untracked and the current local Debug app is identifiable.

- [ ] **Step 2: Create a WIP checkpoint commit without changing file contents.**

```bash
git add -A
git commit -m "wip: checkpoint MyFluidVoice before Soniox integration"
```

Expected: one local checkpoint commit; no unrelated files are deleted or reset.

- [ ] **Step 3: Verify the checkpoint is clean and the important fork changes are present.**

```bash
git status --short
rg -n 'AutoUpdateCheckEnabled|DoubleModifierTapDecision|keep dictation overlay|Include both left and right' Sources/Fluid Tests
```

Expected: clean status and matches for updater, Double-tap, overlay, and checkbox code.

### Task 2: Merge the prerequisite workflow and Soniox history

**Files:**
- Modify: files changed by `091976e^..091976e` as required by the coherent branch history.
- Preserve: current `main` overlay, hotkey, updater, and fork identity behavior during conflict resolution.

**Interfaces:**
- Consumes: clean checkpoint from Task 1.
- Produces: merged source tree containing `DictationSession`, scoped ASR routing, `SonioxConfiguration`, credential service, provider, transport, reducer, settings UI, migrations, and tests.

- [ ] **Step 1: Merge the Soniox-complete branch point.**

```bash
git merge --no-ff 091976e -m "feat: integrate Soniox streaming dictation"
```

Expected: merge stops only for shared files that need manual reconciliation; no automatic reset or checkout is used.

- [ ] **Step 2: Resolve conflicts with the explicit ownership policy.**

For `ContentView.swift`, keep current main's overlay-finalization sequence and Double-tap capture state, then port the branch's session snapshot and Soniox-specific dictation routing around that flow. For `SettingsStore.swift`, keep current updater defaults and hotkey migration while adding Soniox settings/keychain receipt fields. For `GlobalHotkeyManager.swift`, keep current Double-tap handling. For `SettingsView.swift`, keep the modifier both-sides checkbox and add the branch's Soniox settings sections without restoring upstream update controls. For `Info.plist`, `README.md`, and metadata, retain the MyFluidVoice identity and add Soniox privacy disclosure.

```bash
git status --short
git diff --name-only --diff-filter=U
rg -n 'Soniox|doubleModifier|AutoUpdateCheckEnabled|Include both left and right|overlay' Sources/Fluid Tests Info.plist README.md
```

Expected: no unresolved merge markers remain and all required feature ownership points are present.

- [ ] **Step 3: Ensure Soniox source and test files are included in the Xcode target.**

```bash
rg -n 'SonioxProvider|SonioxCredentialSettingsTests|SonioxScopeRoutingTests|SonioxProviderTests' Fluid.xcodeproj/project.pbxproj
git status --short
```

Expected: Soniox Swift sources and all three Soniox test files have project references; no test file is silently omitted.

- [ ] **Step 4: Check the merged tree for syntax and whitespace errors.**

```bash
git diff --check HEAD^ HEAD
rg -n '^(<<<<<<<|=======|>>>>>>>)' . --glob '!DerivedData/**' --glob '!.git/**' || true
```

Expected: `git diff --check` is clean and the conflict-marker search returns no matches.

### Task 3: Verify Soniox behavior and preserve existing hotkey behavior

**Files:**
- Test: `Tests/FluidDictationIntegrationTests/SonioxCredentialSettingsTests.swift`
- Test: `Tests/FluidDictationIntegrationTests/SonioxProviderTests.swift`
- Test: `Tests/FluidDictationIntegrationTests/SonioxScopeRoutingTests.swift`
- Test: `Tests/FluidDictationIntegrationTests/HotkeyShortcutTests.swift`

**Interfaces:**
- Consumes: merged Soniox provider, settings, routing, and current hotkey state machines.
- Produces: test evidence for credential secrecy, WebSocket framing, terminal lifecycle, routing isolation, and Double-tap regression behavior.

- [ ] **Step 1: Build the merged Debug target without signing.**

```bash
xcodebuild -project Fluid.xcodeproj -scheme Fluid -configuration Debug build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Run focused Soniox and hotkey tests.**

```bash
xcodebuild test -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FluidDictationIntegrationTests/SonioxCredentialSettingsTests -only-testing:FluidDictationIntegrationTests/SonioxProviderTests -only-testing:FluidDictationIntegrationTests/SonioxScopeRoutingTests -only-testing:FluidDictationIntegrationTests/HotkeyShortcutTests
```

Expected: all selected tests pass; any existing unrelated failure is recorded by exact test name and message.

- [ ] **Step 3: Run the full macOS test suite.**

```bash
xcodebuild test -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Expected: the xcresult summary reports zero unexpected failures.

### Task 4: Launch and verify the integrated local app

**Files:**
- Generated: `/Users/liooo/Library/Developer/Xcode/DerivedData/Fluid-cqdugkxnrnbyzmabmaxrabxyucib/Build/Products/Debug/FluidVoice Debug.app`

**Interfaces:**
- Consumes: verified Debug build from Task 3.
- Produces: one running local MyFluidVoice process with Soniox settings available and upstream updates disabled.

- [ ] **Step 1: Stop only the previous local Debug process.**

```bash
ps ax -o pid=,args= | rg '/FluidVoice Debug.app/Contents/MacOS/FluidVoice Debug'
local_debug_pid="$(ps ax -o pid=,args= | awk '$0 ~ /\/FluidVoice Debug\.app\/Contents\/MacOS\/FluidVoice Debug/ && $0 !~ /awk/ {print $1; exit}')"
test -n "$local_debug_pid"
kill "$local_debug_pid"
```

Expected: only the exact process from the local DerivedData path is stopped.

- [ ] **Step 2: Launch the newly built app.**

```bash
open '/Users/liooo/Library/Developer/Xcode/DerivedData/Fluid-cqdugkxnrnbyzmabmaxrabxyucib/Build/Products/Debug/FluidVoice Debug.app'
```

Expected: one new process runs from that exact path.

- [ ] **Step 3: Verify persisted/runtime invariants without exposing credentials.**

```bash
defaults read com.FluidApp.app AutoUpdateCheckEnabled
defaults export com.FluidApp.app - | plutil -p - | rg -n 'Soniox|AutoUpdate|PrimaryDictation'
ps ax -o pid=,state=,args= | rg '/FluidVoice Debug.app/Contents/MacOS/FluidVoice Debug'
```

Expected: updater remains disabled, no API key is printed, Soniox settings exist, and exactly one local Debug process is running.

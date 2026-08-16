# Soniox v5 Streaming Dictation Implementation Plan

> **For agentic workers:** REQUIRED: Use the `executing-plans` skill to implement this plan task by task. Follow the red-green-refactor sequence and stop at every review checkpoint before moving to the next task.

**Goal:** Add private BYOK Soniox `stt-rt-v5` realtime dictation with IME-scoped language control, native WebSocket streaming, exact session cancellation, a Keychain-backed setup UI, and a strict local-only fallback for all non-dictation transcription.

**Architecture:** Keep FluidVoice's existing capture, cumulative streaming loop, immutable recording-session snapshot, AI/history/output pipeline, and coordinator ownership. Add only Soniox-specific configuration, credential, wire, reducer, transport, and provider types. A fresh `SonioxProvider` owns one native `URLSessionWebSocketTask` per dictation recording; all file, meeting, dictionary-training, and Local API paths resolve a separately persisted local/system fallback and never construct the cloud provider.

**Tech Stack:** Swift 6.2 / SwiftUI, macOS 15+, `URLSessionWebSocketTask`, Security/Keychain, XCTest, Xcode project `Fluid.xcodeproj`, shared scheme `Fluid`.

## Global Constraints

- Work from `/Users/liooo/ghq/github.com/Liooo/MyFluidVoice/worktrees/feat-just-dictate-workflows` on `feat/just-dictate-workflows`.
- Treat `docs/superpowers/specs/2026-08-16-soniox-v5-streaming-design.md` as the approved source of truth.
- Preserve the existing `ASRService`, `RecordingSpeechConfiguration`, `DictationSessionCoordinator`, streaming preview, AI, history, and output-delivery architecture. Extend them; do not replace them.
- Use test-driven development for every behavior change. Add or change the deterministic test first, run it and observe the intended failure, implement the smallest production change, then rerun it green.
- Automated tests must use fake credential and WebSocket transports. They must never contact Soniox and must never require a real API key.
- Never place the Soniox API key in `UserDefaults`, session configuration, `providerKey`, backup/export data, history, analytics, errors, or logs. The only persisted copy is Keychain provider ID `asr:soniox`.
- Treat Keychain IDs beginning with `asr:` as a reserved speech-credential namespace. Generic AI-provider key dictionaries and editors must neither expose nor overwrite reserved entries.
- Never log Soniox transcript text, raw server frames, configuration JSON, response prose, or secrets. Logs may contain provider/model, sample counts, duration, character counts, stable `error_type`, and `request_id` only.
- Preserve session-ID checks before and after every await or callback that can publish a partial, finish output, mutate history, touch the clipboard, or type text.
- Do not silently reconnect or replay audio within a recording. A terminal Soniox error fails that owned recording once.
- Do not use the local fallback as automatic recovery for a failed Soniox dictation.
- Do not send FluidVoice custom-dictionary, vocabulary-boost, app-context, window-title, or prompt data in the Soniox configuration. Local post-transcription replacement remains unchanged.
- Soniox is dictation-only. File Transcription, Meeting, dictionary training, and Local API transcription must not read the Soniox Keychain entry or instantiate `SonioxProvider`.
- Production Swift files under `Sources/Fluid` are in a filesystem-synchronized Xcode group and need no explicit project membership. Every new test file must be added to the test target's `PBXBuildFile`, `PBXFileReference`, test group, and `PBXSourcesBuildPhase` entries.
- Run formatting/lint only after the behavior is green, inspect the resulting diff, and keep unrelated working-tree changes intact.
- Use focused unsigned Xcode tests during development. Finish with strict lint, the CI-equivalent unsigned suite, the complete suite, and the signed `./build.sh` workflow.

## Task 1: Add Pure Soniox Region and Language Configuration

**Files:**

- Create: `Sources/Fluid/Models/SonioxConfiguration.swift`
- Create: `Tests/FluidDictationIntegrationTests/SonioxProviderTests.swift`
- Modify: `Fluid.xcodeproj/project.pbxproj`

### Step 1: Register the provider test file

- Add one unique `PBXFileReference` for `SonioxProviderTests.swift`.
- Add one unique `PBXBuildFile` referring to it.
- Add the file reference to the `FluidDictationIntegrationTests` group.
- Add the build file to the integration-test target's Sources build phase.
- Run `plutil -lint Fluid.xcodeproj/project.pbxproj` and expect `OK`.

### Step 2: Write failing pure configuration tests

Add `SonioxProviderTests` with table-driven tests for these public module-internal contracts:

```swift
@MainActor
final class SonioxProviderTests: XCTestCase {
    func testRegionBuildsExactRESTAndWebSocketEndpoints() {
        XCTAssertEqual(
            SettingsStore.SonioxRegion.global.verificationModelsURL.absoluteString,
            "https://api.soniox.com/v1/models"
        )
        XCTAssertEqual(
            SettingsStore.SonioxRegion.global.webSocketURL.absoluteString,
            "wss://stt-rt.soniox.com/transcribe-websocket"
        )
        XCTAssertEqual(
            SettingsStore.SonioxRegion.japan.verificationModelsURL.absoluteString,
            "https://api.jp.soniox.com/v1/models"
        )
        XCTAssertEqual(
            SettingsStore.SonioxRegion.japan.webSocketURL.absoluteString,
            "wss://stt-rt.jp.soniox.com/transcribe-websocket"
        )
    }

    func testLanguageModesResolveJapaneseEnglishAndUnsupportedLocales() {
        XCTAssertEqual(
            SonioxLanguageCatalog.binding(
                localeIdentifier: "ja-JP",
                mode: .currentInputSourceOnly,
                region: .japan
            ),
            SonioxSessionBinding(languageCode: "ja", isStrict: true, region: .japan)
        )
        XCTAssertEqual(
            SonioxLanguageCatalog.binding(
                localeIdentifier: "en-US",
                mode: .preferCurrentInputSource,
                region: .global
            ),
            SonioxSessionBinding(languageCode: "en", isStrict: false, region: .global)
        )
        XCTAssertEqual(
            SonioxLanguageCatalog.binding(
                localeIdentifier: "xx-YY",
                mode: .currentInputSourceOnly,
                region: .global
            ),
            SonioxSessionBinding(languageCode: nil, isStrict: false, region: .global)
        )
        XCTAssertEqual(
            SonioxLanguageCatalog.binding(
                localeIdentifier: "ja-JP",
                mode: .automatic,
                region: .global
            ),
            SonioxSessionBinding(languageCode: nil, isStrict: false, region: .global)
        )
    }

    func testNilLanguageAlwaysNormalizesToNonStrict() {
        XCTAssertEqual(
            SonioxSessionBinding(languageCode: nil, isStrict: true, region: .global),
            SonioxSessionBinding(languageCode: nil, isStrict: false, region: .global)
        )
    }

    func testBindingNormalizesSupportedCodeAndRejectsUnsupportedHint() {
        XCTAssertEqual(
            SonioxSessionBinding(languageCode: " JA ", isStrict: true, region: .global),
            SonioxSessionBinding(languageCode: "ja", isStrict: true, region: .global)
        )
        XCTAssertEqual(
            SonioxSessionBinding(languageCode: "xx", isStrict: true, region: .global),
            SonioxSessionBinding(languageCode: nil, isStrict: false, region: .global)
        )
    }
}
```

Also add a table that iterates the exact official language-code set and confirms every supported locale produces that code. Keep the set explicit:

```swift
[
    "af", "sq", "ar", "az", "eu", "be", "bn", "bs", "bg", "ca", "zh", "hr",
    "cs", "da", "nl", "en", "et", "fi", "fr", "gl", "de", "el", "gu", "he",
    "hi", "hu", "id", "it", "ja", "kn", "kk", "ko", "lv", "lt", "mk", "ms",
    "ml", "mr", "no", "fa", "pl", "pt", "pa", "ro", "ru", "sr", "sk", "sl",
    "es", "sw", "sv", "tl", "ta", "te", "th", "tr", "uk", "ur", "vi", "cy",
]
```

Run:

```bash
xcodebuild test \
  -project Fluid.xcodeproj \
  -scheme Fluid \
  -destination 'platform=macOS' \
  -only-testing:FluidDictationIntegrationTests/SonioxProviderTests \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL at compile time because the Soniox configuration types do not exist.

### Step 3: Implement the pure types

Create `SonioxConfiguration.swift` with no credential or mutable-global access:

```swift
import Foundation

extension SettingsStore {
    nonisolated enum SonioxLanguageMode: String, Codable, CaseIterable, Identifiable, Sendable {
        case automatic
        case preferCurrentInputSource
        case currentInputSourceOnly

        var id: String { self.rawValue }
    }

    nonisolated enum SonioxRegion: String, Codable, CaseIterable, Identifiable, Sendable {
        case global
        case japan

        var id: String { self.rawValue }

        var verificationModelsURL: URL {
            self.makeURL(
                scheme: "https",
                host: self == .global ? "api.soniox.com" : "api.jp.soniox.com",
                path: "/v1/models"
            )
        }

        var webSocketURL: URL {
            self.makeURL(
                scheme: "wss",
                host: self == .global ? "stt-rt.soniox.com" : "stt-rt.jp.soniox.com",
                path: "/transcribe-websocket"
            )
        }

        private func makeURL(scheme: String, host: String, path: String) -> URL {
            var components = URLComponents()
            components.scheme = scheme
            components.host = host
            components.path = path
            guard let url = components.url else {
                preconditionFailure("Invalid static Soniox endpoint")
            }
            return url
        }
    }
}

nonisolated struct SonioxSessionBinding: Equatable, Sendable {
    let languageCode: String?
    let isStrict: Bool
    let region: SettingsStore.SonioxRegion

    init(languageCode: String?, isStrict: Bool, region: SettingsStore.SonioxRegion) {
        let normalized = languageCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.languageCode = normalized.flatMap {
            SonioxLanguageCatalog.supportedLanguageCodes.contains($0) ? $0 : nil
        }
        self.isStrict = self.languageCode == nil ? false : isStrict
        self.region = region
    }
}

nonisolated enum SonioxLanguageCatalog {
    static let supportedLanguageCodes: Set<String> = [
        "af", "sq", "ar", "az", "eu", "be", "bn", "bs", "bg", "ca", "zh", "hr",
        "cs", "da", "nl", "en", "et", "fi", "fr", "gl", "de", "el", "gu", "he",
        "hi", "hu", "id", "it", "ja", "kn", "kk", "ko", "lv", "lt", "mk", "ms",
        "ml", "mr", "no", "fa", "pl", "pt", "pa", "ro", "ru", "sr", "sk", "sl",
        "es", "sw", "sv", "tl", "ta", "te", "th", "tr", "uk", "ur", "vi", "cy",
    ]

    static func binding(
        localeIdentifier: String,
        mode: SettingsStore.SonioxLanguageMode,
        region: SettingsStore.SonioxRegion
    ) -> SonioxSessionBinding {
        guard mode != .automatic,
              let code = languageCode(for: localeIdentifier)
        else {
            return SonioxSessionBinding(languageCode: nil, isStrict: false, region: region)
        }
        return SonioxSessionBinding(
            languageCode: code,
            isStrict: mode == .currentInputSourceOnly,
            region: region
        )
    }

    static func languageCode(for localeIdentifier: String) -> String? {
        let locale = Locale(identifier: localeIdentifier)
        guard let identifier = locale.language.languageCode?.identifier.lowercased() else {
            return nil
        }
        let alias = ["nb": "no", "fil": "tl"][identifier] ?? identifier
        return self.supportedLanguageCodes.contains(alias) ? alias : nil
    }
}
```

Add user-facing `displayName` and explanatory `description` properties to the two settings enums in the same file. Do not add `SpeechModel.sonioxV5` yet; this task must remain independently green without temporary ASR fallbacks.

### Step 4: Run the focused test green

Run the same focused command. Expected: all `SonioxProviderTests` currently defined pass, with no network access.

### Step 5: Commit

```bash
git add Sources/Fluid/Models/SonioxConfiguration.swift \
  Tests/FluidDictationIntegrationTests/SonioxProviderTests.swift \
  Fluid.xcodeproj/project.pbxproj
git commit -m "feat: add Soniox region and language configuration"
```

## Task 2: Add Atomic Keychain Save-and-Verify

**Files:**

- Create: `Sources/Fluid/Services/SonioxCredentialService.swift`
- Create: `Tests/FluidDictationIntegrationTests/SonioxCredentialSettingsTests.swift`
- Modify: `Fluid.xcodeproj/project.pbxproj`
- Modify: `Sources/Fluid/Persistence/KeychainService.swift`
- Modify: `Sources/Fluid/Persistence/SettingsStore.swift`

### Step 1: Register and write failing credential tests

Register `SonioxCredentialSettingsTests.swift` in the same four PBX sections used in Task 1. Use fake stores and transports; do not exercise the real login Keychain or network in XCTest.

Define tests with these exact behaviors:

- `testVerificationUsesRegionModelsEndpointBearerHeaderGETAndTenSecondTimeout`
- `testVerificationRequiresHTTP200AndSttRtV5InResponse`
- `testSuccessfulVerificationReplacesPriorKeyExactlyOnce`
- `test401500TimeoutAndMalformedBodyKeepPriorKeyUnchanged`
- `testEmptySaveDeletesWithoutNetworkRequest`
- `testErrorDescriptionContainsStableCategoryAndRequestIDOnly`
- `testCredentialErrorNeverContainsCandidateKeyResponseBodyOrTranscript`
- `testGenerationOrSameRegionRestoreBeforeCommitKeepsPriorKeyAndReceipt`
- `testRegionChangeBeforeCommitKeepsPriorKeyButClearsReceipt`
- `testExplicitTenSecondRaceTimesOutEvenWhenTransportNeverReturns`
- `testVerificationReceiptChangesWithRegionOrKeyWithoutContainingEitherSecretValue`
- `testGenericAIKeyReadsExcludeReservedASRCredentials`
- `testSavingGenericAIKeysAtomicallyPreservesReservedASRCredentials`

Run:

```bash
xcodebuild test \
  -project Fluid.xcodeproj \
  -scheme Fluid \
  -destination 'platform=macOS' \
  -only-testing:FluidDictationIntegrationTests/SonioxCredentialSettingsTests \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL at compile time because the credential protocols and service are absent.

### Step 2: Implement the credential boundary

Use these Soniox-specific, module-internal interfaces:

```swift
import CryptoKit
import Foundation

nonisolated enum SonioxFailureCategory: String, Equatable, Sendable {
    case credential
    case configuration
    case balance
    case limit
    case temporaryService
    case finalizationTimeout
}

nonisolated struct SonioxCredentialError: Error, Equatable, Sendable {
    let category: SonioxFailureCategory
    let diagnosticType: String
    let requestID: String?

    static let staleVerification = SonioxCredentialError(
        category: .credential,
        diagnosticType: "stale_verification",
        requestID: nil
    )

    static let apiKeyRequired = SonioxCredentialError(
        category: .credential,
        diagnosticType: "api_key_required",
        requestID: nil
    )

    static func notVerifiedForRegion(
        _ region: SettingsStore.SonioxRegion
    ) -> SonioxCredentialError {
        _ = region // never include the selected endpoint or credential in user-facing copy
        return SonioxCredentialError(
            category: .credential,
            diagnosticType: "credential_not_verified_for_region",
            requestID: nil
        )
    }
}

protocol SonioxCredentialStoring {
    func fetchAPIKey() throws -> String?
    func replaceAPIKey(_ value: String) throws
    func removeAPIKey() throws
}

struct KeychainSonioxCredentialStore: SonioxCredentialStoring {
    static let providerID = "asr:soniox"

    private let keychain: KeychainService

    init(keychain: KeychainService = .shared) {
        self.keychain = keychain
    }

    func fetchAPIKey() throws -> String? {
        try self.keychain.fetchKey(for: Self.providerID)
    }

    func replaceAPIKey(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            try self.removeAPIKey()
            return
        }
        try self.keychain.storeKey(trimmed, for: Self.providerID)
    }

    func removeAPIKey() throws {
        try self.keychain.deleteKey(for: Self.providerID)
    }
}

nonisolated protocol SonioxModelsTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

typealias SonioxCredentialSleep =
    @Sendable (Duration) async throws -> Void

protocol SonioxCredentialVerifying {
    func verify(apiKey: String, region: SettingsStore.SonioxRegion) async throws
}

nonisolated struct SonioxVerificationReceipt: Codable, Equatable, Sendable {
    let region: SettingsStore.SonioxRegion
    let credentialFingerprint: String

    static func make(
        apiKey: String,
        region: SettingsStore.SonioxRegion
    ) -> SonioxVerificationReceipt {
        SonioxVerificationReceipt(
            region: region,
            credentialFingerprint: self.fingerprint(apiKey: apiKey)
        )
    }

    static func fingerprint(apiKey: String) -> String {
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum SonioxCredentialMutationResult: Equatable, Sendable {
    case removed
    case verified(SonioxVerificationReceipt)
}

@MainActor
final class SonioxCredentialService {
    private let store: any SonioxCredentialStoring
    private let verifier: any SonioxCredentialVerifying

    init(
        store: any SonioxCredentialStoring = KeychainSonioxCredentialStore(),
        verifier: any SonioxCredentialVerifying = SonioxCredentialVerifier()
    ) {
        self.store = store
        self.verifier = verifier
    }

    func saveAndVerify(
        apiKey: String,
        region: SettingsStore.SonioxRegion,
        commitIfCurrent: @escaping @MainActor () -> Bool
    ) async throws -> SonioxCredentialMutationResult {
        let candidate = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.isEmpty == false else {
            try self.store.removeAPIKey()
            return .removed
        }
        try await self.verifier.verify(apiKey: candidate, region: region)
        guard commitIfCurrent() else {
            throw SonioxCredentialError.staleVerification
        }
        try self.store.replaceAPIKey(candidate)
        return .verified(.make(apiKey: candidate, region: region))
    }

    func remove() throws {
        try self.store.removeAPIKey()
    }

    func storedCredentialFingerprint() throws -> String? {
        let value = try self.store.fetchAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, value.isEmpty == false else { return nil }
        return SonioxVerificationReceipt.fingerprint(apiKey: value)
    }
}
```

`SonioxCredentialVerifier` must:

1. Create a `GET` request using `region.verificationModelsURL`.
2. Set `Authorization: Bearer <candidate>` and `timeoutInterval = 10` as URLSession defense in depth.
3. Require HTTP status 200 according to the official endpoint contract.
4. Decode only the model identifiers needed to confirm `stt-rt-v5` is available.
5. Convert HTTP, timeout, decoding, and model-unavailable failures into a `SonioxCredentialError` that stores only a stable category, a bounded safe diagnostic type, and optional sanitized `requestID`. Table-test 401/403 as `.credential`, 402 as `.balance`, 429 as `.limit`, a successful response missing `stt-rt-v5` as `.configuration`, and timeout/other non-200/malformed response as `.temporaryService`.
6. Race the transport against an injected `SonioxCredentialSleep` armed for ten seconds; the clock winner must cancel and await the request task before returning `.temporaryService`, even if `URLRequest.timeoutInterval` is not honored promptly.
7. Never retain or interpolate the candidate key, response body, mutable server message, or request payload in an error.

The production transport may wrap `URLSession.shared.data(for:)`; the initializer must accept a fake `SonioxModelsTransport` and injected sleep for tests. Use a cancellation-responsive suspended fake to prove the explicit clock race deterministically without wall-clock waiting.

The receipt is non-secret verification metadata: it contains the selected region and a one-way
SHA-256 fingerprint of the normalized, high-entropy key, never the key itself. `commitIfCurrent` is
evaluated on MainActor after verification and immediately before the synchronous Keychain replace,
so a region/restore/generation change during the request cannot replace the prior credential. A
stale verification fails without touching Keychain. The caller persists the returned receipt
immediately after the method returns, with no intervening await; a crash in that tiny window leaves
the new key conservatively unverified.

### Step 3: Reserve the ASR credential namespace

`KeychainService` currently stores all provider keys in one aggregate item, while
`SettingsStore.providerAPIKeys` is the generic AI-provider view. Add one atomic Keychain operation
that replaces generic keys while retaining all existing IDs with the reserved `asr:` prefix. Keep
the merge rule pure and directly testable:

```swift
nonisolated static func replacingUnreservedKeys(
    existing: [String: String],
    replacements: [String: String],
    reservedPrefix: String = "asr:"
) -> [String: String] {
    var result = existing.filter { $0.key.hasPrefix(reservedPrefix) }
    result.merge(replacements.filter { $0.key.hasPrefix(reservedPrefix) == false }) { _, new in new }
    return result
}
```

The instance method must load, merge, and save within one synchronous MainActor-isolated call. Then:

- filter reserved IDs out of `SettingsStore.providerAPIKeys` reads;
- make `saveProviderAPIKeys` call the preserving replace operation instead of `storeAllKeys`;
- return only generic AI keys to `ContentView` and `AIEnhancementSettingsViewModel`;
- leave direct Soniox access exclusively in `KeychainSonioxCredentialStore`.

This prevents a generic AI settings save from deleting the Soniox credential and prevents
`asr:soniox` from becoming an AI post-processing candidate or UI draft.

### Step 4: Prove atomic replacement

Make the fake store count fetch/replace/remove calls and retain a sentinel old key. In every failure test assert:

```swift
XCTAssertEqual(store.currentKey, "old-key")
XCTAssertEqual(store.replaceCallCount, 0)
```

On success, assert replacement happens only after the fake transport has returned a valid model list. On empty input, assert `removeCallCount == 1` and `transport.requests.isEmpty`. Also table-test the reserved-key merge helper with add/update/delete operations on generic keys while `asr:soniox` remains byte-for-byte unchanged.

### Step 5: Run focused tests and lint touched files

Run the focused command until green. Then run:

```bash
swiftlint lint --strict \
  Sources/Fluid/Services/SonioxCredentialService.swift \
  Sources/Fluid/Persistence/KeychainService.swift \
  Sources/Fluid/Persistence/SettingsStore.swift \
  Tests/FluidDictationIntegrationTests/SonioxCredentialSettingsTests.swift
```

Expected: zero violations.

### Step 6: Commit

```bash
git add Sources/Fluid/Services/SonioxCredentialService.swift \
  Sources/Fluid/Persistence/KeychainService.swift \
  Sources/Fluid/Persistence/SettingsStore.swift \
  Tests/FluidDictationIntegrationTests/SonioxCredentialSettingsTests.swift \
  Fluid.xcodeproj/project.pbxproj
git commit -m "feat: verify Soniox credentials before Keychain storage"
```

## Task 3: Add the Soniox Wire Format, Reducer, and Native Transport

**Files:**

- Create: `Sources/Fluid/Services/SonioxWebSocketTransport.swift`
- Create: `Sources/Fluid/Services/SonioxTranscriptReducer.swift`
- Modify: `Tests/FluidDictationIntegrationTests/SonioxProviderTests.swift`

### Step 1: Write failing reducer and wire tests

Add tests:

- `testStartFrameContainsKeyModelPCMShapeAndEndpointDetectionDisabled`
- `testAutomaticModeOmitsLanguageHintsAndStrictFieldIsFalse`
- `testStrictJapaneseModeSendsSingleJaHint`
- `testPCMEncodingIsFloat32LittleEndian`
- `testReducerAppendsFinalAndReplacesWholeProvisionalSuffix`
- `testReducerConcatenatesExactTextWithoutInventedWhitespace`
- `testReducerRemovesControlMarkersAndPreservesRepeatedWords`
- `testReducerConfidenceUsesOnlyTranscriptTokensWithConfidence`
- `testErrorTypeTableMapsEveryOfficialSlugToOneStableUserCategory`
- `testUnknownOrMalformedErrorTypeFallsBackToTemporaryServiceWithoutProse`
- `testRequestIDIsRetainedOnlyWhenItMatchesTheBoundedSafeCharacterSet`
- `testEverySonioxFailureCategoryMapsToFixedUserFacingTitleAndMessage`

Use an example evolution such as:

```swift
let first = SonioxServerMessage(tokens: [
    .init(text: "こん", isFinal: false, confidence: 0.8),
])
let second = SonioxServerMessage(tokens: [
    .init(text: "こんにちは", isFinal: true, confidence: 0.9),
    .init(text: "世", isFinal: false, confidence: 0.7),
])
let third = SonioxServerMessage(tokens: [
    .init(text: "世界", isFinal: false, confidence: 0.8),
])

XCTAssertEqual(reducer.reduce(first).completeText, "こん")
XCTAssertEqual(reducer.reduce(second).completeText, "こんにちは世")
XCTAssertEqual(reducer.reduce(third).completeText, "こんにちは世界")
```

Run the focused `SonioxProviderTests` command. Expected: FAIL because the wire and reducer types do not exist.

### Step 2: Implement transport-neutral frames and native adapter

Create the exact fakeable boundary:

```swift
nonisolated enum SonioxWebSocketFrame: Equatable, Sendable {
    case text(String)
    case binary(Data)
}

nonisolated enum SonioxTransportCloseDisposition: Sendable {
    case normal
    case cancelled
}

nonisolated protocol SonioxWebSocketTransport: AnyObject, Sendable {
    func start() async throws
    func send(_ frame: SonioxWebSocketFrame) async throws
    func receive() async throws -> SonioxWebSocketFrame
    func close(_ disposition: SonioxTransportCloseDisposition)
}

typealias SonioxTransportFactory =
    @Sendable (URL) -> any SonioxWebSocketTransport

typealias SonioxSleep =
    @Sendable (Duration) async throws -> Void
```

Implement `URLSessionSonioxWebSocketTransport` using one `URLSessionWebSocketTask`. Requirements:

- Expose `static func make(_ endpoint: URL) -> any SonioxWebSocketTransport` for the production factory default used by `SonioxProvider`.
- `start()` resumes exactly once.
- `send` and `receive` translate only between the wrapper frame and `URLSessionWebSocketTask.Message`.
- `close` is synchronous and idempotent.
- Both `close(.normal)` and `close(.cancelled)` must close/cancel the underlying task so a pending `receive()` is unblocked.
- Declare the adapter class and `static nonisolated func make(_:)` explicitly nonisolated and Sendable-safe under the target's default MainActor isolation.
- The adapter never logs the message body or close reason.
- No third-party SDK and no generic cloud-provider abstraction.

### Step 3: Implement request and response wire values

Use `Encodable`/`Decodable` values with explicit snake-case coding keys:

```swift
nonisolated struct SonioxStartMessage: Encodable, Sendable {
    let apiKey: String
    let model = "stt-rt-v5"
    let audioFormat = "pcm_f32le"
    let sampleRate = 16_000
    let numChannels = 1
    let languageHints: [String]?
    let languageHintsStrict: Bool
    let enableEndpointDetection = false

    private enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case model
        case audioFormat = "audio_format"
        case sampleRate = "sample_rate"
        case numChannels = "num_channels"
        case languageHints = "language_hints"
        case languageHintsStrict = "language_hints_strict"
        case enableEndpointDetection = "enable_endpoint_detection"
    }
}

nonisolated struct SonioxServerMessage: Decodable, Sendable {
    let tokens: [SonioxToken]
    let finished: Bool
    let errorType: String?
    let requestID: String?

    init(
        tokens: [SonioxToken] = [],
        finished: Bool = false,
        errorType: String? = nil,
        requestID: String? = nil
    ) {
        self.tokens = tokens
        self.finished = finished
        self.errorType = errorType
        self.requestID = requestID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tokens = try container.decodeIfPresent([SonioxToken].self, forKey: .tokens) ?? []
        self.finished = try container.decodeIfPresent(Bool.self, forKey: .finished) ?? false
        self.errorType = try container.decodeIfPresent(String.self, forKey: .errorType)
        self.requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
    }

    private enum CodingKeys: String, CodingKey {
        case tokens, finished
        case errorType = "error_type"
        case requestID = "request_id"
    }
}

nonisolated struct SonioxToken: Decodable, Equatable, Sendable {
    let text: String
    let isFinal: Bool
    let confidence: Float?

    private enum CodingKeys: String, CodingKey {
        case text, confidence
        case isFinal = "is_final"
    }
}
```

Give missing `tokens` and `finished` safe decode defaults. Reject malformed JSON before it can update transcript state. Encode the start JSON only at the point of sending it; never stringify it for diagnostics.

Reuse Task 2's shared `SonioxFailureCategory` and add a streaming error value that never stores server prose or payloads:

```swift
nonisolated struct SonioxError: Error, Equatable, Sendable {
    let category: SonioxFailureCategory
    let diagnosticType: String
    let requestID: String?
}
```

Implement one pure `SonioxErrorMapper` with this exact table from the current STT WebSocket error contract:

| Stable category | `error_type` values |
|---|---|
| `.credential` | `unauthenticated`, `temp_api_key_session_expired` |
| `.configuration` | `invalid_request`, `model_not_available` |
| `.balance` | `organization_balance_exhausted`, `organization_monthly_budget_exhausted`, `project_monthly_budget_exhausted` |
| `.limit` | `limit_exceeded` |
| `.temporaryService` | `request_timeout`, `max_duration_reached`, `internal_error`, `service_unavailable`, unknown server values, URLSession/network failure, malformed response, and early close |
| `.finalizationTimeout` | the local ten-second timeout armed after sending `finalize`; it is not a server slug |

Implementation references: [STT WebSocket API](https://soniox.com/docs/api-reference/stt/websocket-api) and [API errors](https://soniox.com/docs/api-reference/errors), reviewed 2026-08-16. If Soniox adds a new stable slug before implementation, add it with a failing table row first; do not infer behavior from mutable prose.

Normalize a diagnostic `error_type` only when it matches `[a-z0-9_]{1,64}`; otherwise store `unknown_error_type`. Retain a `request_id` only when it matches `[A-Za-z0-9_-]{1,128}`; otherwise store nil. These two sanitized diagnostics may be logged, but neither is interpolated into the fixed user-facing title/message. Unknown slugs fail closed as `.temporaryService`; never branch on `error_message` or other mutable prose.

In the same pure mapper, define the fixed user-facing copy needed by setup and runtime failures:

| Category | Title | Message |
|---|---|---|
| `.credential` | `Soniox API Key Required` | `Check or re-verify the Soniox API key for the selected region in Voice Engine settings.` |
| `.configuration` | `Soniox Configuration Error` | `The selected Soniox model or audio configuration is unavailable.` |
| `.balance` | `Soniox Balance Exhausted` | `Add balance or increase the project budget in Soniox, then try again.` |
| `.limit` | `Soniox Usage Limit Reached` | `The Soniox concurrency or rate limit was reached. Try again shortly.` |
| `.temporaryService` | `Soniox Temporarily Unavailable` | `Check the network connection and try again.` |
| `.finalizationTimeout` | `Soniox Finalization Timed Out` | `Soniox did not finish the transcription in time. Try again.` |

Table-test all six mappings in this task. A sanitized request ID is carried separately and never changes this copy.

### Step 4: Implement the pure reducer and audio encoder

```swift
nonisolated struct SonioxTranscriptSnapshot: Equatable, Sendable {
    let completeText: String
    let finalText: String
    let confidence: Float
    let sawFin: Bool
    let sawEnd: Bool
    let finished: Bool
}

nonisolated struct SonioxTokenReducer: Sendable {
    mutating func reduce(_ message: SonioxServerMessage) throws -> SonioxTranscriptSnapshot
    mutating func reset()
}
```

Reducer invariants:

- Append the response's final transcript tokens once, in response order.
- Replace the whole provisional suffix with the response's non-final transcript tokens.
- Never deduplicate by token text; valid repeated words must remain.
- Concatenate the exact token text; never guess a space.
- Treat `<fin>` and `<end>` as distinct control markers only. They set `sawFin` and `sawEnd` respectively but never enter visible text or confidence. Only `sawFin` may satisfy the manual-finalization waiter.
- Track confidence sum/count separately for committed and current provisional tokens, so replacement removes the prior provisional contribution.
- If `error_type` is present, throw a typed sanitized Soniox error before mutating transcript state.

Add a pure PCM helper that emits each Float's `bitPattern.littleEndian` bytes. Test exact known bit patterns. Framing into 960-sample chunks belongs to the provider in Task 4.

### Step 5: Run focused tests and commit

Run the provider tests until green, run strict lint on the three touched files, then:

```bash
git add Sources/Fluid/Services/SonioxWebSocketTransport.swift \
  Sources/Fluid/Services/SonioxTranscriptReducer.swift \
  Tests/FluidDictationIntegrationTests/SonioxProviderTests.swift
git commit -m "feat: add Soniox WebSocket wire protocol"
```

## Task 4: Implement the Per-Recording Soniox Provider State Machine

**Files:**

- Create: `Sources/Fluid/Services/SonioxProvider.swift`
- Modify: `Sources/Fluid/Services/TranscriptionProvider.swift`
- Modify: `Sources/Fluid/Services/WhisperProvider.swift`
- Modify: `Tests/FluidDictationIntegrationTests/SonioxProviderTests.swift`

### Step 1: Write failing provider lifecycle tests

Add a controllable fake transport that records frames, can suspend `receive()`, can enqueue server messages/errors, and reports close calls. Add a manual sleeper whose continuation is released by the test rather than wall-clock sleeps.

Tests:

- `testPrepareValidatesSnapshotKeyWithoutOpeningSocket`
- `testFirstPreviewSendsConfigurationBeforeAudio`
- `testCumulativePrefixesSendOnlyNewSuffixIn960SampleFrames`
- `testEqualPrefixReturnsSnapshotWithoutAnotherBinaryFrame`
- `testShrinkingPrefixFailsWithoutReconnecting`
- `testPreviewReturnsLatestSnapshotWithoutWaitingForNextResponse`
- `testFinalizationWithoutPriorPreviewConnectsAndConfiguresBeforeAudio`
- `testFinalizationWireOrderAndFinalOnlyResult`
- `testTimeoutStartsOnlyAfterFinalizeSendCompletes`
- `testDiscardWhileWaitingForFinCancelsReceiveAndAllWaiters`
- `testParentTaskCancellationClosesTransportBeforeAwaitingProviderCleanup`
- `testTransportFailureAtStartConfigurationAudioFinalizeAndEmptyFrameIsTerminal`
- `testMalformedTextAndUnexpectedBinaryResponseFailAndClearState`
- `testCloseBeforeFinAndCloseAfterFinBeforeFinishedUnblockWithoutOutput`
- `testLateFinAndFinishedAfterTimeoutCannotPublishOutput`
- `testResetAfterCancellationIsIdempotent`
- `testFreshProviderStartsAtSampleZeroWithNewTransport`

The finalization-order assertion must distinguish actual remaining PCM, 3,200 zero samples split into frames no larger than 960 samples, the text finalize frame, an empty binary frame, and normal close.

Run focused tests. Expected: FAIL because `SonioxProvider` is missing.

### Step 2: Extend the provider contract only where the finalizer needs it

Add these defaults to `TranscriptionProvider`:

```swift
var minimumFinalAudioSampleCount: Int { get }
var allowsTranscriptLogging: Bool { get }
```

Default both in the protocol extension:

```swift
var minimumFinalAudioSampleCount: Int { 0 }
var allowsTranscriptLogging: Bool { true }
```

Override `WhisperProvider.minimumFinalAudioSampleCount` to `16_000`. Do not alter provider-specific internal padding. Override Soniox `allowsTranscriptLogging` to `false`.

### Step 3: Implement the thin provider and isolated session actor

Use this interface:

```swift
final class SonioxProvider: TranscriptionProvider {
    static let modelID = "stt-rt-v5"

    let name = "Soniox v5 Realtime"
    let isAvailable = true
    private(set) var isReady = false
    let shouldClearCacheAfterCancellation = false
    let allowsTranscriptLogging = false

    init(
        apiKey: String,
        binding: SonioxSessionBinding,
        transportFactory: @escaping SonioxTransportFactory = URLSessionSonioxWebSocketTransport.make,
        sleep: @escaping SonioxSleep = SonioxProvider.productionSleep,
        finalizationTimeout: Duration = .seconds(10)
    )
}

private final nonisolated class SonioxCancellationHandle: @unchecked Sendable {
    func install(_ transport: any SonioxWebSocketTransport)
    func cancel() // lock-protected, synchronous, idempotent; calls close(.cancelled)
    func clear()
}

private actor SonioxStreamingSession {
    func preview(cumulativeSamples: [Float]) async throws -> ASRTranscriptionResult
    func finalize(cumulativeSamples: [Float]) async throws -> ASRTranscriptionResult
    func resetAfterCancellation() async
}
```

Implementation requirements:

- `prepare()` trims and validates the constructor-snapshotted key, marks ready, and does not open a socket.
- `transcribe(_:)` delegates to `transcribeFinal(_:)`.
- `transcribeStreaming(_:)` and `transcribeFinal(_:)` delegate into one actor that serializes all socket/reducer/sample state.
- `modelsExistOnDisk()` returns `true` because no artifact is required; UI credential readiness is separate.
- `clearCache()` only resets volatile provider state. It must not delete a Keychain credential.
- `resetAfterCancellation()` awaits the actor cleanup and is idempotent.

The actor must:

1. Reject `samples.count < sentSampleCount` as a local invariant failure.
2. Return the current snapshot without sending when counts are equal.
3. On first non-empty suffix, create the selected region socket and send the configuration text frame exactly once before audio.
4. Split only the unsent suffix into at-most-960-sample Float32 little-endian frames.
5. Advance `sentSampleCount` only after the corresponding frame send succeeds.
6. Keep one receive task that continuously decodes and reduces messages; return from that loop immediately after reducing `finished == true`.
7. Store a terminal receive error and throw it before/after later sends; never reconnect.
8. Return the actor's latest completed snapshot immediately after preview sends.

Finalization must execute this order exactly:

1. Send remaining captured suffix.
2. Send 3,200 Float zeros, split into at-most-960-sample frames.
3. Send `{"type":"finalize"}`.
4. Arm the injected ten-second timeout only after that send succeeds.
5. Await a reduced `<fin>` marker.
6. Send an empty binary frame.
7. Await `finished == true`.
8. Return only accumulated final text.
9. Close the transport normally before awaiting the receive task, cancel any remaining timeout task, resume/clear waiters, and clear the reducer, transport, cancellation handle, and sample count. Normal close must unblock a receive that has not already returned on `finished`.

Failure from transport start, configuration send, any PCM send, finalize send, empty-binary send, timeout, cancellation, malformed/unexpected response, server error, or socket close before the required terminal state must synchronously call `close(.cancelled)` before awaiting task termination, fail all pending waiters once, and clear every volatile field. A close before `<fin>` and a close after `<fin>` but before `finished` both fail finalization. Every failure is terminal for that provider; there is no reconnect or retry. Late fake events after cleanup must not change the snapshot or complete a caller.

Wrap every provider call that can suspend on the actor (`transcribeStreaming`, `transcribeFinal`, and cancellation-sensitive prepare/cleanup work) in `withTaskCancellationHandler`. The synchronous handler must invoke the lock-protected `SonioxCancellationHandle.cancel()` outside actor isolation. Install the active transport in that handle as soon as it is created and clear it only after cleanup. This is required because the existing executor drain cancels and awaits the transcription operation before it calls `provider.resetAfterCancellation()`; a finalizer waiting on `<fin>` must have its pending `receive()` broken immediately by task cancellation rather than waiting for the later reset call.

Declare `URLSessionSonioxWebSocketTransport.make` and `SonioxProvider.productionSleep` explicitly `nonisolated` and `@Sendable`-compatible so `SonioxStreamingSession` can invoke the defaults without an implicit MainActor hop.

### Step 4: Run focused tests, then the provider contract build

Run:

```bash
xcodebuild test \
  -project Fluid.xcodeproj \
  -scheme Fluid \
  -destination 'platform=macOS' \
  -only-testing:FluidDictationIntegrationTests/SonioxProviderTests \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

xcodebuild build \
  -project Fluid.xcodeproj \
  -scheme Fluid \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: focused tests pass and all existing providers satisfy the extended protocol.

### Step 5: Commit

```bash
git add Sources/Fluid/Services/SonioxProvider.swift \
  Sources/Fluid/Services/TranscriptionProvider.swift \
  Sources/Fluid/Services/WhisperProvider.swift \
  Tests/FluidDictationIntegrationTests/SonioxProviderTests.swift
git commit -m "feat: add per-recording Soniox streaming provider"
```

## Task 5: Establish the Local-Only Boundary with a Hidden Cloud Case

**Files:**

- Create: `Tests/FluidDictationIntegrationTests/SonioxScopeRoutingTests.swift`
- Modify: `Fluid.xcodeproj/project.pbxproj`
- Modify: `Sources/Fluid/Persistence/SettingsStore.swift`
- Modify: `Sources/Fluid/Persistence/BackupService.swift`
- Modify: `Sources/Fluid/Persistence/VoiceEngineLanguageCatalog.swift`
- Modify: `Sources/Fluid/Services/KeyboardInputSourceService.swift`
- Modify: `Sources/Fluid/Services/ASRService.swift`
- Modify: `Sources/Fluid/Services/MeetingTranscriptionService.swift`
- Modify: `Sources/Fluid/Services/LocalAPI/InferenceAPIController.swift`
- Modify: `Sources/Fluid/Services/AutomaticDictionaryTrainingSession.swift`
- Modify: `Sources/Fluid/ContentView.swift`
- Modify: `Sources/Fluid/UI/AISettingsView.swift`
- Modify: `Sources/Fluid/UI/AISettings/VoiceEngineSettingsViewModel.swift`
- Modify: `Sources/Fluid/UI/CustomDictionaryView.swift`
- Modify: `Sources/Fluid/UI/MeetingTranscriptionView.swift`
- Modify: `Sources/Fluid/UI/WelcomeView.swift`

### Step 1: Register and write only the failing local-scope tests

Register `SonioxScopeRoutingTests.swift` in the test target's four PBX sections. Create a fake local provider factory with call counters and add only these tests in this task:

- `testHiddenSonioxMetadataIsCloudStreamingNoArtifactAndNotSelectable`
- `testActivatingLocalModelUpdatesLocalFallback`
- `testActivatingSonioxPreservesPriorLocalFallback`
- `testMissingInvalidCloudOrUnsupportedFallbackNormalizesToPlatformDefault`
- `testLegacyInstallInitializesFallbackFromCurrentLocalSelection`
- `testBackupRoundTripsFallbackAndRejectsCloudFallback`
- `testDictionaryTrainingUsesLocalFallbackWhenGlobalModelIsSoniox`
- `testFileAndMeetingUseLocalFallbackWhenGlobalModelIsSoniox`
- `testLocalAPISampleAndFileUseLocalFallbackAndReportItsName`

Run only the new scope suite. Expected: compile/test failures for the absent hidden cloud-model case, fallback setting, and local-only factory.

### Step 2: Add model metadata without making it selectable yet

Add:

```swift
case sonioxV5 = "soniox-v5"
```

and provider group:

```swift
case soniox = "Soniox"
```

Add explicit domain properties:

```swift
var isCloudSpeechModel: Bool { self == .sonioxV5 }
var requiresCredential: Bool { self == .sonioxV5 }
var requiresModelDownload: Bool {
    switch self {
    case .appleSpeech, .appleSpeechAnalyzer, .sonioxV5:
        return false
    default:
        return true
    }
}
var backendModelIdentifier: String {
    self == .sonioxV5 ? SonioxProvider.modelID : self.rawValue
}
```

Update every exhaustive `SpeechModel` switch in `SettingsStore.swift`, including:

- `displayName`, `languageSupport`, `downloadSize`, `expectedDownloadBytes`
- `humanReadableName`, `cardDescription`, `requiredMemoryGB`
- speed/accuracy ratings and percentages, badge, Apple optimization
- `supportsStreaming`, preview interval, minimum preview duration
- provider, installed/artifact behavior, brand name/color
- architecture/OS availability, language compatibility, delete/download paths

Use these Soniox metadata values consistently:

| Property | Value |
|---|---|
| `displayName` / `humanReadableName` | `Soniox v5 Realtime` |
| `languageSupport` | `60+ Languages (Automatic or IME Hint)` |
| `downloadSize` | `Cloud (usage billed by Soniox)` |
| `expectedDownloadBytes` / `requiredMemoryGB` | `0` |
| `isInstalled` | `true` (no local artifact; credential state is separate) |
| `supportsStreaming` | `true` |
| preview interval / minimum | `0.1` / `0.1` seconds |
| speed rating / percent | `5` / `0.95` |
| accuracy rating / percent | `5` / `0.98` |
| provider / brand | `Soniox` |
| Apple Silicon optimized | `false` (network model, universal) |
| badge | `Cloud` |

Because `availableModels` starts from `allCases`, add an explicit temporary `if model == .sonioxV5 { return false }` filter in this task. That keeps Soniox out of `availableModels`, `compatibleModels`, provider filters, onboarding, and model menus while the enum and exhaustive metadata compile. The hidden-metadata test must fail if this gate is omitted. Task 8 removes this exact gate only after its cloud UI paths are complete. Do not build or commit any intermediate state with a selectable Soniox model.

### Step 3: Persist and normalize the local fallback before cloud exposure

Add:

```swift
var localFallbackSpeechModel: SpeechModel

static func normalizedLocalFallbackSpeechModel(
    _ candidate: SpeechModel?,
    availableModels: [SpeechModel] = SpeechModel.availableModels,
    defaultModel: SpeechModel = SpeechModel.defaultModel
) -> SpeechModel
```

Rules:

- A fallback must be non-cloud and present in the injected/current `availableModels` for the CPU/OS.
- It need not be downloaded; the existing local readiness path may download/load it when that workflow starts.
- Missing, corrupt, cloud, or platform-incompatible values normalize to the injected/current platform default.
- On first read with no fallback key, adopt current `selectedSpeechModel` only when it is a valid local/system model; otherwise use the platform default.
- The `selectedSpeechModel` setter updates the fallback only for a valid local/system selection. Selecting Soniox preserves it.

Add optional raw `localFallbackSpeechModelID: String?` to `SettingsBackupPayload`. Decode legacy payloads, normalize unknown/cloud values, and never include credentials or verification state.

Split the ambiguous global APIs:

```swift
static func currentDictationFallbackConfiguration(
    settings: SettingsStore = .shared
) -> RecordingSpeechConfiguration

static func currentLocalFallbackConfiguration(
    settings: SettingsStore = .shared
) -> RecordingSpeechConfiguration
```

In `ASRService`, add a local-only factory whose type contract rejects cloud models and which has no credential-store dependency or Soniox branch:

```swift
private func makeLocalProvider(
    for configuration: RecordingSpeechConfiguration
) throws -> TranscriptionProvider

func preparedLocalFallbackProvider() async throws -> TranscriptionProvider
```

Remove/replace `fileTranscriptionProvider`, because it can expose the active dictation provider. `ASRService.start` chooses `currentLocalFallbackConfiguration()` whenever `forDictionaryTraining == true` and no explicit configuration was supplied; normal dictation uses `currentDictationFallbackConfiguration()`.

### Step 4: Route every non-dictation caller through the local factory

- Meeting and File Transcription obtain one `preparedLocalFallbackProvider()` and use that same provider for readiness and transcription.
- Automatic and custom-dictionary training pass an explicit local fallback configuration.
- Local API sample/file requests use the local factory and report `localFallbackSpeechModel.displayName`.
- Meeting/File/dictionary UI shows the saved local fallback name and ordinary local readiness/download state when Soniox is global.
- Pronunciation-matching eligibility in `CustomDictionaryView` uses the local fallback, never global Soniox.
- No scope path catches a Soniox failure and retries locally.

Make the fake local-factory counters prove every non-dictation route resolves the saved local model and never asks for the active/global dictation provider. This boundary must be green and committed before Task 6 constructs the cloud runtime path; Task 8 is the only task that makes Soniox selectable.

### Step 5: Prove and commit the local-only boundary

Run:

```bash
xcodebuild test \
  -project Fluid.xcodeproj \
  -scheme Fluid \
  -destination 'platform=macOS' \
  -only-testing:FluidDictationIntegrationTests/SonioxScopeRoutingTests \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

xcodebuild build \
  -project Fluid.xcodeproj \
  -scheme Fluid \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: all scope tests pass, every non-dictation route uses the expected local fake, and the unsigned app builds while the hidden cloud enum is still absent from every selectable list.

Commit:

```bash
git add Tests/FluidDictationIntegrationTests/SonioxScopeRoutingTests.swift \
  Fluid.xcodeproj/project.pbxproj \
  Sources/Fluid/Persistence/SettingsStore.swift \
  Sources/Fluid/Persistence/BackupService.swift \
  Sources/Fluid/Persistence/VoiceEngineLanguageCatalog.swift \
  Sources/Fluid/Services/KeyboardInputSourceService.swift \
  Sources/Fluid/Services/ASRService.swift \
  Sources/Fluid/Services/MeetingTranscriptionService.swift \
  Sources/Fluid/Services/LocalAPI/InferenceAPIController.swift \
  Sources/Fluid/Services/AutomaticDictionaryTrainingSession.swift \
  Sources/Fluid/ContentView.swift \
  Sources/Fluid/UI/AISettingsView.swift \
  Sources/Fluid/UI/AISettings/VoiceEngineSettingsViewModel.swift \
  Sources/Fluid/UI/CustomDictionaryView.swift \
  Sources/Fluid/UI/MeetingTranscriptionView.swift \
  Sources/Fluid/UI/WelcomeView.swift
git commit -m "feat: keep non-dictation transcription local"
```

## Task 6: Add Soniox Settings, IME Resolution, and Fresh Provider Construction

**Files:**

- Modify: `Sources/Fluid/Persistence/SettingsStore.swift`
- Modify: `Sources/Fluid/Persistence/BackupService.swift`
- Modify: `Sources/Fluid/Persistence/VoiceEngineLanguageCatalog.swift`
- Modify: `Sources/Fluid/Models/DictationSession.swift`
- Modify: `Sources/Fluid/Services/KeyboardInputSourceService.swift`
- Modify: `Sources/Fluid/Services/ASRService.swift`
- Modify: `Sources/Fluid/ContentView.swift`
- Modify: `Sources/Fluid/UI/AISettingsView.swift`
- Modify: `Sources/Fluid/UI/AISettings/VoiceEngineSettingsViewModel.swift`
- Modify: `Sources/Fluid/UI/WelcomeView.swift`
- Modify: `Tests/FluidDictationIntegrationTests/DictationE2ETests.swift`
- Modify: `Tests/FluidDictationIntegrationTests/SonioxCredentialSettingsTests.swift`
- Modify: `Tests/FluidDictationIntegrationTests/SonioxScopeRoutingTests.swift`

### Step 1: Write failing settings, resolver, factory, and setup-error tests

Add tests for:

- The default Soniox language mode being `.currentInputSourceOnly` and default region `.global`.
- Region changes retaining the stored Keychain key but clearing `sonioxVerificationReceipt`.
- The immutable Soniox binding ID containing region, code-or-auto, and strictness, but no key.
- A Japanese per-IME assignment resolving `.sonioxV5`, `ja`, strict, and the sampled region.
- A globally selected Soniox model with no per-IME assignment resolving the sampled Japanese input source to `ja`/strict and a sampled US input source to `en`/strict. The global selection must not return a prebuilt locale-agnostic binding.
- Changing IME/language mode/region after resolution not mutating the existing configuration.
- Changing the Keychain value after provider construction not mutating that recording's snapshotted credential.
- Unsupported locales producing automatic/non-strict binding.
- A model/binding mismatch being rejected by `RecordingSpeechConfiguration.init?`.
- Legacy backup JSON decoding with no Soniox fields.
- New backups including language mode and region but excluding key and verification-receipt metadata.
- A fresh Soniox recording reading the Keychain once and constructing a new provider; the next recording gets a distinct provider.
- A missing or receipt-mismatched credential producing one sanitized owned-session setup failure, closing the overlay, and adding no history/output.
- `testNonDictationRoutesNeverFetchSonioxCredentialOrBuildSonioxProvider`
- `testFailedSonioxDictationDoesNotInvokeLocalFallbackFactory`

Run the relevant `DictationE2ETests` and credential suite. Expected: failures for the absent settings, binding, resolver behavior, and factory.

### Step 2: Persist non-secret Soniox settings

Add keys and properties:

```swift
var sonioxLanguageMode: SonioxLanguageMode       // default .currentInputSourceOnly
var sonioxRegion: SonioxRegion                   // default .global
var sonioxVerificationReceipt: SonioxVerificationReceipt? // nil until successful verification
```

The `sonioxRegion` setter must clear `sonioxVerificationReceipt` when the value changes. It must not touch Keychain. The credential UI will persist the exact receipt returned after `saveAndVerify` succeeds and clear it after key removal.

Extend `SettingsBackupPayload` with backward-compatible optional raw strings:

```swift
let sonioxLanguageModeID: String?
let sonioxRegionID: String?
```

Include these two in `makeBackupPayload`/restore, mapping recognized raw values and defaulting unknown values safely. Raw strings are deliberate: a future/unknown enum value must not make the entire synthesized backup decoder fail before normalization. Do not add the API key or `sonioxVerificationReceipt` to any backup type.

### Step 3: Add immutable binding and IME-aware resolver inputs

Add to `VoiceEngineLanguageRoute.LanguageBinding`:

```swift
case soniox(SonioxSessionBinding)
```

Its `id` must be deterministic from region, language code or `auto`, and strictness. Update `apply` for exhaustive behavior, but do not add a Soniox onboarding route candidate. Update the explicit `WelcomeView` switches to return false/no-op for the unreachable Soniox route rather than falling through ambiguously.

Update `RecordingSpeechConfiguration` compatibility:

```swift
case (.sonioxV5, .soniox):
    return true
```

and reject `.soniox` with every other model and `.sonioxV5` with every other binding.

Update resolver signatures so Soniox mode/region are explicit inputs:

```swift
static func globalFallbackConfiguration(
    model: SettingsStore.SpeechModel,
    selectedLanguageID: String,
    appleLocaleIdentifier: String,
    cohereLanguage: SettingsStore.CohereLanguage,
    nemotronLanguage: SettingsStore.NemotronLanguage,
    sonioxLanguageMode: SettingsStore.SonioxLanguageMode,
    sonioxRegion: SettingsStore.SonioxRegion
) -> RecordingSpeechConfiguration?

static func resolve(
    inputSource: KeyboardInputSourceSnapshot?,
    assignedModel: SettingsStore.SpeechModel?,
    globalFallback: RecordingSpeechConfiguration,
    sonioxLanguageMode: SettingsStore.SonioxLanguageMode,
    sonioxRegion: SettingsStore.SonioxRegion,
    availableModels: [SettingsStore.SpeechModel] = SettingsStore.SpeechModel.availableModels,
    fallbackLocaleIdentifier: String = Locale.current.identifier
) -> RecordingSpeechConfiguration
```

The resolver must select `assignedModel ?? globalFallback.model` first. If that resolved model is Soniox, derive a new immutable Soniox binding from the sampled `inputSource` even when `assignedModel == nil`; do not return the prebuilt global fallback binding. Japanese therefore resolves to `ja`, US/Roman to `en`, and unsupported/unknown to automatic according to the sampled language mode. Non-Soniox global fallback behavior remains unchanged.

In `ContentView.beginDictationSession`, sample the input source, assignment, Soniox language mode, and region once; pass all snapshots to the resolver before creating the coordinator session. Never place a Keychain value in this configuration.

### Step 4: Create a fresh provider and an owned setup-failure seam

Change `ASRService.makeRecordingProvider(for:)` to throw a sanitized setup error rather than returning an ambiguous nil. Inject `SonioxCredentialStoring` and `SonioxTransportFactory` into `ASRService.init` with production defaults and test overrides.

For the Soniox case, before the current cached-provider branch:

```swift
case let (.sonioxV5, .soniox(binding)):
    guard let apiKey = try self.sonioxCredentialStore.fetchAPIKey(),
          apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    else {
        throw SonioxCredentialError.apiKeyRequired
    }
    let expectedReceipt = SonioxVerificationReceipt.make(
        apiKey: apiKey,
        region: binding.region
    )
    guard SettingsStore.shared.sonioxVerificationReceipt == expectedReceipt else {
        throw SonioxCredentialError.notVerifiedForRegion(binding.region)
    }
    return SonioxProvider(
        apiKey: apiKey,
        binding: binding,
        transportFactory: self.sonioxTransportFactory
    )
```

Do not assign this provider to `cachedRecordingProvider`, any global provider field, or a provider key that contains the API key. Every recording must execute this branch once and receive a new provider. `activeRecordingSpeechModel` and `hasActiveRecordingSession` should expose the session-owned model/state for the UI without exposing the provider or credential.

Make `RecordingSessionID` `Hashable` and `Sendable`, and add the failure seam here so provider construction can fail without being swallowed by `AudioCaptureStartOutcome.failed`:

```swift
nonisolated struct ASRRecordingFailure: Equatable, Sendable {
    let sessionID: RecordingSessionID
    let category: SonioxFailureCategory
    let title: String
    let message: String
    let requestID: String?
}

func setRecordingFailureHandler(
    _ handler: (@MainActor (ASRRecordingFailure) -> Void)?
)
```

In `ASRService.start`, install the immutable recording selection first, then construct the provider in `do/catch`. Convert missing/unverified/keychain setup failures through the Task 3 sanitized mapping, emit the handler once for the same session ID, clear only matching session-owned state, and return `.failed`. Never fall through to a cached or local provider.

Install the handler in `ContentView` before starting capture. It must require that the coordinator still owns the failure's session ID, cancel that coordinator session/finalization task, dismiss the overlay through the existing failure path, and present the sanitized title/message. Stale failures are ignored; this path never adds history, copies, types, or promotes a partial.

Update `getProvider(for:)`, download/delete/readiness paths to reject cloud download operations with a typed “credentials are configured in Voice Engine” result rather than using Whisper or another fallback.

### Step 5: Keep the completed runtime path hidden until the credential UI is safe

Do **not** add Soniox to `availableModels`, provider filters, `compatibleModels`, onboarding, or any model menu in this task. Tests that exercise resolution must inject an available-model list containing `.sonioxV5`; lifecycle tests may construct the immutable configuration directly. This lets the factory/session work compile and be tested without exposing the current local-artifact card, trash action, or eager `ensureAsrReady()` activation behavior. Task 8 implements the cloud card and credential gate first, then makes Soniox selectable as its last production step.

Update only exhaustive switches in `AISettingsView.swift`, `VoiceEngineSettingsViewModel.swift`, and `WelcomeView.swift` to a safe unreachable no-op/configure result required for compilation. Non-dictation UI continues to display the local fallback from Task 5.

### Step 6: Run tests and commit

Run:

```bash
xcodebuild test \
  -project Fluid.xcodeproj \
  -scheme Fluid \
  -destination 'platform=macOS' \
  -only-testing:FluidDictationIntegrationTests/DictationE2ETests \
  -only-testing:FluidDictationIntegrationTests/SonioxCredentialSettingsTests \
  -only-testing:FluidDictationIntegrationTests/SonioxScopeRoutingTests \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

xcodebuild build \
  -project Fluid.xcodeproj \
  -scheme Fluid \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: all resolver/settings/session/fresh-provider/scope tests pass, every non-dictation fake Soniox counter remains zero, the unsigned app builds, and the hidden metadata test still proves Soniox is absent from selectable lists.

Commit:

```bash
git add Sources/Fluid/Persistence/SettingsStore.swift \
  Sources/Fluid/Persistence/BackupService.swift \
  Sources/Fluid/Persistence/VoiceEngineLanguageCatalog.swift \
  Sources/Fluid/Models/DictationSession.swift \
  Sources/Fluid/Services/KeyboardInputSourceService.swift \
  Sources/Fluid/Services/ASRService.swift \
  Sources/Fluid/ContentView.swift \
  Sources/Fluid/UI/AISettingsView.swift \
  Sources/Fluid/UI/AISettings/VoiceEngineSettingsViewModel.swift \
  Sources/Fluid/UI/WelcomeView.swift \
  Tests/FluidDictationIntegrationTests/DictationE2ETests.swift \
  Tests/FluidDictationIntegrationTests/SonioxCredentialSettingsTests.swift \
  Tests/FluidDictationIntegrationTests/SonioxScopeRoutingTests.swift
git commit -m "feat: add scoped Soniox dictation selection"
```

## Task 7: Integrate Graceful Finalization, Failure, and Cancellation with ASRService

**Files:**

- Modify: `Sources/Fluid/Services/ASRService.swift`
- Modify: `Sources/Fluid/ContentView.swift`
- Modify: `Tests/FluidDictationIntegrationTests/SonioxProviderTests.swift`
- Modify: `Tests/FluidDictationIntegrationTests/AudioEngineRetirementDrainTests.swift`
- Modify: `Tests/FluidDictationIntegrationTests/DictationE2ETests.swift`

### Step 1: Write deterministic lifecycle failures first

Add tests using fake providers/transports and controlled continuations, never timing sleeps:

- `testGracefulQuiesceDoesNotCancelInFlightPreviewSocket`
- `testDiscardStillHardCancelsInFlightPreviewAndReceive`
- `testNoAudioAndShortSilenceResetOpenedProviderWithoutFinalizing`
- `testSonioxReceivesActualShortPCMWithoutOneSecondAppPadding`
- `testWhisperStillReceivesAtLeastOneSecondOfFinalAudio`
- `testStreamingTerminalErrorClearsPartialAndReportsOwnedSessionOnce`
- `testStreamingTerminalErrorStopsCaptureBeforeDismissingAndClearsMatchingSelection`
- `testSonioxFinalErrorDoesNotPromotePartialToFinalOutput`
- `testStaleSessionErrorCannotCancelOrPublishIntoNewSession`
- `testTerminationClosesOpenSonioxSocketAndUnblocksReceive`
- `testSonioxTranscriptAndConfigurationNeverReachDebugMessages`
- `testFailedSonioxSessionDoesNotForceAudioHistoryPersistence`
- `testOwnedFailureShowsSanitizedRequestIDButNeverDiagnosticSlugOrServerProse`

Run the focused suites and observe failures in the current timer cancellation, early-return cleanup, unconditional padding, and swallowed streaming-error paths.

### Step 2: Separate graceful quiesce from destructive cancellation

Keep `cancelStreamingTranscriptionAndAwait(provider:sessionID:)` as the discard/termination hard-cancel path.

Add a normal-stop method such as:

```swift
func quiesceStreamingForFinalization(
    provider: TranscriptionProvider,
    sessionID: RecordingSessionID
) async
```

It must:

- mark the session's streaming loop as stop-requested;
- cancel only an idle interval sleep;
- allow an already-entered `processStreamingChunk`/executor operation to finish normally;
- await the loop before reading/clearing the cumulative buffer;
- preserve the provider/socket for `transcribeFinal`;
- recheck session ownership after every await.

The streaming loop must distinguish “graceful stop requested” from `Task.isCancelled`. Do not let normal finalization call `provider.resetAfterCancellation()`.

### Step 3: Make final padding provider-owned

Replace the unconditional 16,000-sample padding with:

```swift
let minimumSamples = provider.minimumFinalAudioSampleCount
if pcm.count < minimumSamples {
    pcm.append(contentsOf: repeatElement(0, count: minimumSamples - pcm.count))
}
```

This sends exact captured PCM to Soniox; Soniox adds only its protocol-required 200 ms silence internally. Preserve the unpadded captured snapshot for optional audio history.

### Step 4: Close state on all early exits

Before returning for no audio, short silence, provider-not-ready, discard, start failure after provider creation, or termination:

- clear `partialTranscription` and `previousFullTranscription` for the matching session;
- cancel the matching worker/executor/preparation tasks first, which synchronously fires Soniox's task-cancellation handle and closes the socket before any await;
- await those matching worker/executor/receive tasks in the existing owner-scoped drain order;
- only after the workers have drained, `await provider.resetAfterCancellation()` to clear actor state;
- clear readiness keys and active provider only if the session ID/provider key still matches;
- then clear the recording selection.

Do not call the actor-isolated reset before cancelling a worker that may be suspended inside `finalize`/`receive`; doing so can enqueue reset behind the blocked operation. Do not reset or cancel an unrelated Local API/file operation. Use the existing executor owner ID rather than a global cancellation call.

### Step 5: Route terminal errors once through the owned failure seam

Reuse Task 6's `RecordingSessionID: Hashable & Sendable`, `ASRRecordingFailure`, and handler, plus Task 3's fixed category-to-copy conversion. No caller may derive text from server prose or the raw diagnostic slug. When a sanitized `requestID` is present, the error surface adds a separate `Request ID: …` line for support. It never shows `diagnosticType`, `error_message`, response bodies, frames, configuration, transcript, or key.

Have `processStreamingChunk` return a typed `StreamingChunkOutcome`, including
`.terminalFailure(ASRRecordingFailure)`, instead of starting a drain from inside itself. On a
terminal Soniox preview error, the streaming loop must observe that outcome, exit, and then perform
session cleanup from its own completion path without calling any helper that awaits
`self.streamingTask`. The existing `cancelStreamingTranscriptionAndAwait` cannot be called from
inside `streamingTask`, because it would await itself.

Store a separate owner-scoped completion-monitor task when the streaming worker is created. The monitor awaits the worker's value; only after that worker has returned may it handle `.terminalFailure` by awaiting `stopWithoutTranscription(sessionID:)`. That stop must end microphone capture, close/reset the matching provider, drain only work owned by that recording, and keep the recording selection installed until cleanup completes. Only then may the monitor clear the matching selection and invoke the MainActor failure handler. The monitor must recheck the session ID/provider key before and after every await. Do not use `Task.yield()` or timing to avoid the self-await race.

For a terminal Soniox preview/final error:

1. Confirm the active selection and provider key still match.
2. Record/report at most one failure for that session ID.
3. Clear volatile partial text.
4. If the error came from preview, let the current executor operation and loop return first, then reset the provider/socket directly; if it came from an external discard/final path, use the normal owner-scoped hard-cancel drain.
5. From the separate completion monitor, `await stopWithoutTranscription(sessionID:)` and confirm capture/provider/session-owned state are stopped and cleared.
6. Send the sanitized failure to `ContentView` only after that stop completes.

`ContentView` must use the failure's session ID to cancel the same coordinator session and existing finalization task, dismiss the recording UI, and show one existing error surface. If the coordinator no longer owns that ID, ignore the callback. This path must never add history, copy, type, or promote the last partial.

For Soniox, remove or guard existing log lines that interpolate raw/final/partial text. Log only safe metadata and `SonioxError`'s stable category/request ID. Never log `NSError.userInfo` for a Soniox error.

### Step 6: Run lifecycle suites and commit

Run:

```bash
xcodebuild test \
  -project Fluid.xcodeproj \
  -scheme Fluid \
  -destination 'platform=macOS' \
  -only-testing:FluidDictationIntegrationTests/SonioxProviderTests \
  -only-testing:FluidDictationIntegrationTests/AudioEngineRetirementDrainTests \
  -only-testing:FluidDictationIntegrationTests/DictationE2ETests \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: all lifecycle tests pass without sleeps or real network.

Commit:

```bash
git add Sources/Fluid/Services/ASRService.swift \
  Sources/Fluid/ContentView.swift \
  Tests/FluidDictationIntegrationTests/SonioxProviderTests.swift \
  Tests/FluidDictationIntegrationTests/AudioEngineRetirementDrainTests.swift \
  Tests/FluidDictationIntegrationTests/DictationE2ETests.swift
git commit -m "feat: scope Soniox streaming to recording lifecycle"
```

## Task 8: Add Voice Engine Credential and Cloud-Model UI

**Files:**

- Modify: `Sources/Fluid/Persistence/SettingsStore.swift`
- Modify: `Sources/Fluid/UI/AISettings/VoiceEngineSettingsViewModel.swift`
- Modify: `Sources/Fluid/UI/AISettings/VoiceEngineSettingsView.swift`
- Modify: `Sources/Fluid/UI/AISettingsView+SpeechRecognition.swift`
- Modify: `Sources/Fluid/UI/AISettingsView.swift`
- Modify: `Tests/FluidDictationIntegrationTests/SonioxCredentialSettingsTests.swift`
- Modify: `Tests/FluidDictationIntegrationTests/DictationE2ETests.swift`

### Step 1: Write failing pure UI-state tests

Define and test pure resolvers:

```swift
nonisolated enum SonioxCredentialState: Equatable, Sendable {
    case apiKeyRequired
    case verifying
    case configured(needsRegionVerification: Bool)
    case ready
}

nonisolated enum SonioxCredentialStateResolver {
    static func resolve(
        storedCredentialFingerprint: String?,
        receipt: SonioxVerificationReceipt?,
        selectedRegion: SettingsStore.SonioxRegion,
        isVerifying: Bool,
        activeModel: SettingsStore.SpeechModel?
    ) -> SonioxCredentialState
}

nonisolated enum SpeechModelCardAction: Equatable, Sendable {
    case configureCredential
    case activate
    case download
    case cancelDownload
    case deleteArtifact
    case none
}

nonisolated enum SpeechModelCardActionResolver {
    static func resolve(
        model: SettingsStore.SpeechModel,
        isActive: Bool,
        isInstalled: Bool,
        isDownloading: Bool,
        credentialState: SonioxCredentialState?
    ) -> SpeechModelCardAction
}
```

Tests:

- no stored key => `API Key Required`;
- verification in flight => `Verifying`;
- key stored but selected region not verified => `Configured` with “Verify for selected region” detail;
- key verified and idle => `Configured`;
- active session model `.sonioxV5` => `Ready`;
- another active model never shows Soniox `Ready`;
- `SpeechModelCardActionResolver` never resolves a Soniox model to download/delete/cached actions;
- Soniox is absent from `availableModels` before this task's production change and present after the cloud card, credential gate, and no-eager-readiness branch are installed;
- key-draft editing, Save, Remove, and region change are blocked while verifying or while `asr.hasActiveRecordingSession`, including finalization;
- failed verification keeps the prior verified key and status;
- a generation change or same-region backup restore while verification is suspended invalidates the generation and preserves the prior key/receipt;
- a region change while verification is suspended invalidates the generation, preserves the prior Keychain key, and clears the now-inapplicable receipt;
- successful verification sets the returned `sonioxVerificationReceipt` immediately after Keychain replacement;
- removal clears key and verification receipt;
- Soniox remains absent from onboarding routes.

Run the focused credential/settings tests and observe failures.

### Step 2: Add the view-model state and dependency injection

Add injected `SonioxCredentialService` and state:

```swift
@Published var sonioxAPIKeyDraft = ""
@Published private(set) var storedSonioxCredentialFingerprint: String?
@Published private(set) var isVerifyingSonioxCredential = false
@Published private(set) var sonioxCredentialError: String?

var sonioxCredentialState: SonioxCredentialState {
    SonioxCredentialStateResolver.resolve(
        storedCredentialFingerprint: self.storedSonioxCredentialFingerprint,
        receipt: self.settings.sonioxVerificationReceipt,
        selectedRegion: self.settings.sonioxRegion,
        isVerifying: self.isVerifyingSonioxCredential,
        activeModel: self.asr.activeRecordingSpeechModel
    )
}

func refreshStoredSonioxCredentialFingerprint()
func saveAndVerifySonioxAPIKey() async
func removeSonioxAPIKey()
```

`saveAndVerify` must:

1. Refuse while ASR owns a recording/finalization.
2. Increment a verification generation, set verifying state, and clear only the prior UI error.
3. Snapshot candidate, selected region, and generation.
4. Await `credentialService.saveAndVerify(..., commitIfCurrent:)`; the closure must require the same generation, the same selected region, and no active ASR session immediately before Keychain replacement.
5. For `.verified(receipt)`, persist that exact receipt immediately with no intervening await; for `.removed`, clear the receipt.
6. Refresh `storedSonioxCredentialFingerprint` from the credential service without exposing the key.
7. Clear the draft after success so the UI does not retain/display the key unnecessarily.
8. On failure, leave the prior stored key and prior verification receipt unchanged and show only a sanitized message.

An empty save and explicit Remove both delete the key and clear the receipt. Disable the `SecureField` itself, Save, Remove, and region editing while verifying or while `hasActiveRecordingSession` is true, so the visible draft cannot diverge from the candidate already under verification.

Keep credential state computed from the pure resolver rather than a manually refreshed published enum. The resolver must compare the cached stored-key fingerprint with `receipt.credentialFingerprint` as well as the selected region. Subscribe the view model to `settings.objectWillChange`, `asr.objectWillChange`, and the existing backup-restore notification. Every backup-restore notification must increment the verification generation before refreshing the cached fingerprint, even when the restored region equals the current region, so an in-flight pre-restore candidate cannot commit. A changed region clears the receipt through its setter; a same-region restore preserves the prior receipt. Refresh the cached fingerprint on view appearance, restore, and credential mutations. This keeps `Ready` synchronized with session ownership/finalization and detects an out-of-band key change on the next explicit refresh without storing or exposing the key.

### Step 3: Render a cloud-specific model card before local artifact logic

In `speechModelCard`, branch on `model.isCloudSpeechModel` before download/cache/delete rendering. The Soniox card must show:

- provider/brand Soniox and model `stt-rt-v5`;
- credential state label;
- Configure/Activate behavior based on verification;
- no Download, Cached, artifact progress, or Delete controls;
- the same active/per-IME checkmark behavior as existing models once verified.

In `VoiceEngineSettingsViewModel.activateSpeechModel`, add an explicit Soniox branch: persist the selection, update preview/provider-filter state, reset any old local provider, and return without calling `ensureAsrReady()`. Soniox connects/prepares only when a real recording owns a fresh provider. Local/system activation keeps the existing eager readiness behavior.

For per-IME menus, route missing/unverified credentials to the Soniox setup section rather than invoking local model download. Never mutate the assignment after a failed credential gate.

### Step 4: Add the Soniox configuration section

Add:

- `SecureField` for the draft key;
- `Save & Verify` and `Remove Key`;
- language picker with Automatic / Prefer Current Input Source / Current Input Source Only;
- region picker with Global / Japan;
- a Japan note explaining that a Japan project and region-specific key are required;
- links to Soniox console, security/privacy, and data residency;
- disclosure that microphone audio goes directly to Soniox and Soniox bills the user's account.

Do not show or prefill the stored key. A placeholder may indicate that a key is saved. The UI may hold the current draft only for the edit/verification operation.

### Step 5: Expose Soniox only after the safe UI paths exist

As the final production change in this task, remove Task 5's explicit `.sonioxV5` exclusion from `SpeechModel.availableModels`; its existing host filters then admit it universally, and the derived provider filters and IME `compatibleModels` expose it while onboarding remains explicitly excluded. Unsupported/unknown locales remain selectable because Task 6 resolves them to automatic detection rather than manufacturing a hint.

Extend the metadata test to assert Soniox is selectable on injected Intel/Apple-Silicon and macOS 15/26 host capabilities with no architecture/newer-OS restriction, while retaining cloud/BYOK, streaming, 100 ms preview cadence/minimum, and no-artifact behavior. Use injected host/available-model inputs rather than asserting the current Mac twice.

At this point every newly reachable global and per-IME entry must pass through the cloud-specific card/action resolver and credential gate. There must be no commit or build in which Soniox is selectable while local artifact actions or eager `ensureAsrReady()` can run.

### Step 6: Run focused tests, build, and commit

Run:

```bash
xcodebuild test \
  -project Fluid.xcodeproj \
  -scheme Fluid \
  -destination 'platform=macOS' \
  -only-testing:FluidDictationIntegrationTests/SonioxCredentialSettingsTests \
  -only-testing:FluidDictationIntegrationTests/DictationE2ETests \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

xcodebuild build \
  -project Fluid.xcodeproj \
  -scheme Fluid \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: focused tests and unsigned build pass. Inspect both global model selection and per-IME model menus in SwiftUI previews or the built app; this is a non-network UI check.

Commit:

```bash
git add Sources/Fluid/Persistence/SettingsStore.swift \
  Sources/Fluid/UI/AISettings/VoiceEngineSettingsViewModel.swift \
  Sources/Fluid/UI/AISettings/VoiceEngineSettingsView.swift \
  Sources/Fluid/UI/AISettingsView+SpeechRecognition.swift \
  Sources/Fluid/UI/AISettingsView.swift \
  Tests/FluidDictationIntegrationTests/SonioxCredentialSettingsTests.swift \
  Tests/FluidDictationIntegrationTests/DictationE2ETests.swift
git commit -m "feat: add Soniox credential settings UI"
```

## Task 9: Add Backward-Compatible History Metadata and Privacy Disclosure

**Files:**

- Modify: `Sources/Fluid/Persistence/TranscriptionHistoryStore.swift`
- Modify: `Sources/Fluid/ContentView.swift`
- Modify: `Info.plist`
- Modify: `README.md`
- Modify: `Tests/FluidDictationIntegrationTests/DictationE2ETests.swift`
- Modify: `Tests/FluidDictationIntegrationTests/SonioxCredentialSettingsTests.swift`

### Step 1: Write failing history/privacy tests

Add tests:

- `testLegacyHistoryDecodesNilSpeechProviderAndModel`
- `testSonioxHistoryRoundTripsProviderAndBackendModelID`
- `testReplacingAudioPreservesSpeechMetadata`
- `testDiscardAndFailedSonioxSessionsAddNoHistory`
- `testBackupJSONContainsNoSonioxCredentialOrVerificationReceipt`
- `testSanitizedSonioxFailureContainsNoTranscriptOrKey`

The new Soniox history assertion should expect provider `soniox` and backend model `stt-rt-v5`, not the API key, region, or language restriction.

Run `DictationE2ETests`; expect failures for missing fields.

### Step 2: Extend history with optional metadata

Add backward-compatible optional strings:

```swift
let speechProvider: String?
let speechModel: String?
```

Thread them through both initializers, `CodingKeys`, `decodeIfPresent`, `replacingAudio`, and `TranscriptionHistoryStore.addEntry`. Existing call sites use default nil.

Update `currentTranscriptionModelInfo(speechConfiguration:)` so it uses
`selectedModel.backendModelIdentifier`. At successful dictation delivery, pass the already-immutable
values stored in `DictationFinalDeliveryContext.transcriptionModelInfo`:

```swift
speechProvider: context.transcriptionModelInfo.provider,
speechModel: context.transcriptionModelInfo.model
```

Do this only after the coordinator's final output claim and only for successful routed output. Discard, failure, no-audio, and stale sessions remain history-free. Never derive metadata from mutable global settings after recording.

### Step 3: Update privacy strings and README

Use accurate permission text that covers local models, Apple Speech, and Soniox. For example:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>MyFluidVoice needs microphone access to capture dictation. On-device models process audio locally. When you choose Soniox, microphone audio is sent to Soniox for transcription. Apple Speech may use Apple's speech service.</string>
<key>NSSpeechRecognitionUsageDescription</key>
<string>MyFluidVoice uses Apple Speech when you select an Apple speech model. macOS may process that audio on-device or through Apple's speech service.</string>
```

Update the README privacy section to state:

- Soniox is opt-in BYOK and selected per global/IME model.
- Audio/transcripts go directly from the Mac to the selected Soniox regional endpoint and usage is billed by Soniox.
- The API key is stored in macOS Keychain only.
- Soniox states realtime audio/transcripts are not retained or used for training; link the official current policy without restating it as MyFluidVoice's guarantee.
- Japan residency requires a Japan-region project, key, and endpoint.
- MyFluidVoice's optional local history/audio history and diagnostic behavior are separate.
- File, Meeting, dictionary training, and Local API remain on the displayed local fallback.

Do not claim MyFluidVoice never stores transcripts; it can persist optional local history.

### Step 4: Run tests, lint docs, and commit

Run focused history/credential tests, `plutil -lint Info.plist`, and `git diff --check`.

Commit:

```bash
git add Sources/Fluid/Persistence/TranscriptionHistoryStore.swift \
  Sources/Fluid/ContentView.swift \
  Info.plist README.md \
  Tests/FluidDictationIntegrationTests/DictationE2ETests.swift \
  Tests/FluidDictationIntegrationTests/SonioxCredentialSettingsTests.swift
git commit -m "docs: disclose Soniox cloud dictation privacy"
```

## Task 10: Full Verification, Signed Build, and Manual Acceptance

**Files:**

- Modify only if verification exposes a defect in the approved scope.
- Record results in the PR/body or final handoff; do not add generated build products to Git.

### Step 1: Format and run strict lint

```bash
./scripts/format-and-lint.sh
git diff --check
git status --short
```

Expected: SwiftFormat completes, SwiftLint reports zero strict violations, diff check is clean. Inspect and revert only unrelated formatter churn with `apply_patch`; do not discard user changes.

If formatting changes Soniox files, rerun all focused Soniox tests before committing a dedicated formatting fix.

### Step 2: Run all focused Soniox suites together

```bash
xcodebuild test \
  -project Fluid.xcodeproj \
  -scheme Fluid \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:FluidDictationIntegrationTests/SonioxProviderTests \
  -only-testing:FluidDictationIntegrationTests/SonioxCredentialSettingsTests \
  -only-testing:FluidDictationIntegrationTests/SonioxScopeRoutingTests \
  -only-testing:FluidDictationIntegrationTests/AudioEngineRetirementDrainTests \
  -only-testing:FluidDictationIntegrationTests/DictationE2ETests \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: zero failures and zero unexpected skips.

### Step 3: Run the CI-equivalent unsigned suite

```bash
xcodebuild test \
  -project Fluid.xcodeproj \
  -scheme Fluid \
  -destination 'platform=macOS,arch=arm64' \
  -skip-testing:FluidDictationIntegrationTests/DictationE2ETests/testDictationEndToEnd_whisperTiny_transcribesFixture \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: the complete CI suite passes, with only the pre-existing explicitly skipped Whisper Tiny fixture.

### Step 4: Run the complete local suite

```bash
xcodebuild test \
  -project Fluid.xcodeproj \
  -scheme Fluid \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: all unit/integration tests, including the local Whisper fixture, pass. If a pre-existing environment/model-cache failure remains, capture the exact failing test and demonstrate that the CI-equivalent suite and all Soniox suites are green; do not hide it.

### Step 5: Build the exact signed Debug app

```bash
./build.sh
codesign --verify --deep --strict --verbose=2 \
  "DerivedData/Build/Products/Debug/MyFluidVoice Debug.app"
open "DerivedData/Build/Products/Debug/MyFluidVoice Debug.app"
```

Expected: the signed build completes, deep/strict verification succeeds, and the exact produced app launches. Do not substitute an unsigned build for manual microphone/Accessibility acceptance.

### Step 6: Complete manual acceptance with the private Soniox account

Verify and record each result:

1. Save and verify a Global key; wrong key, timeout, and wrong-region key leave the prior key usable and show sanitized errors.
2. Assign Soniox to Japanese IME; confirm live Japanese partials and one final output through the normal AI/history/typing path.
3. Assign or resolve US/Roman input; confirm the next recording uses `en`.
4. Change IME, language mode, region, and key during/around recordings; confirm the active snapshot never mutates and editing is blocked while owned.
5. Exercise Automatic, Prefer, and Current Input Source Only with Japanese and mixed Japanese/English speech.
6. Exercise Double Shift toggle and push-to-talk; confirm finalization occurs exactly once.
7. Discard during partial reception, waiting for `<fin>`, and AI processing; confirm no late history, clipboard mutation, or typed text.
8. Remove/replace the key; confirm the next recording uses a fresh provider/socket and the old provider is never reused.
9. Confirm Soniox card has no Download/Cached/Delete actions and onboarding contains no Soniox route.
10. Confirm File, Meeting, dictionary training, and Local API display/use the local fallback and make no Soniox request.
11. If a Japan-enabled account is available, verify the Japan endpoint. Otherwise record the unavailable-account limitation and still verify the wrong-region failure is sanitized.
12. Inspect exported backup JSON and app logs: no key, configuration frame, raw Soniox response, or Soniox transcript text may appear.

### Step 7: Final review checkpoint

- Request an adversarial code review focused on actor cancellation, continuation resumption, session-ID gates, credential redaction, and non-dictation scope.
- Apply only validated fixes, with a deterministic regression test first.
- Rerun the focused suites and the affected full verification command after every fix.
- Confirm `git status --short` contains only intended work and no build products.
- Report changed files, exact test counts/results, signed app path, manual scenarios, and known limitations.

If verification requires a final repair commit, stage each validated repair file by its explicit path
and commit it with `git commit -m "fix: harden Soniox session integration"`.

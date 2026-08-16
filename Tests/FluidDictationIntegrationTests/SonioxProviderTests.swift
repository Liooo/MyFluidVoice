@testable import FluidVoice_Debug
import XCTest

@MainActor
final class SonioxProviderTests: XCTestCase {
    func testStartFrameContainsKeyModelPCMShapeAndEndpointDetectionDisabled() throws {
        let message = SonioxStartMessage(
            apiKey: "test-key",
            languageHints: ["en"],
            languageHintsStrict: false
        )
        let data = try JSONEncoder().encode(message)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["api_key"] as? String, "test-key")
        XCTAssertEqual(object["model"] as? String, "stt-rt-v5")
        XCTAssertEqual(object["audio_format"] as? String, "pcm_f32le")
        XCTAssertEqual(object["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(object["num_channels"] as? Int, 1)
        XCTAssertEqual(object["enable_endpoint_detection"] as? Bool, false)
    }

    func testAutomaticModeOmitsLanguageHintsAndStrictFieldIsFalse() throws {
        let message = SonioxStartMessage(
            apiKey: "test-key",
            languageHints: nil,
            languageHintsStrict: false
        )
        let data = try JSONEncoder().encode(message)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(object["language_hints"])
        XCTAssertEqual(object["language_hints_strict"] as? Bool, false)
    }

    func testStrictJapaneseModeSendsSingleJaHint() throws {
        let message = SonioxStartMessage(
            apiKey: "test-key",
            languageHints: ["ja"],
            languageHintsStrict: true
        )
        let data = try JSONEncoder().encode(message)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["language_hints"] as? [String], ["ja"])
        XCTAssertEqual(object["language_hints_strict"] as? Bool, true)
    }

    func testPCMEncodingIsFloat32LittleEndian() {
        XCTAssertEqual(
            SonioxPCMEncoder.float32LittleEndian([1, -2.5]),
            Data([0x00, 0x00, 0x80, 0x3f, 0x00, 0x00, 0x20, 0xc0])
        )
    }

    func testReducerAppendsFinalAndReplacesWholeProvisionalSuffix() throws {
        var reducer = SonioxTokenReducer()
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

        XCTAssertEqual(try reducer.reduce(first).completeText, "こん")
        XCTAssertEqual(try reducer.reduce(second).completeText, "こんにちは世")
        XCTAssertEqual(try reducer.reduce(third).completeText, "こんにちは世界")
    }

    func testReducerConcatenatesExactTextWithoutInventedWhitespace() throws {
        var reducer = SonioxTokenReducer()
        let snapshot = try reducer.reduce(SonioxServerMessage(tokens: [
            .init(text: "hello", isFinal: true, confidence: nil),
            .init(text: "world", isFinal: false, confidence: nil),
        ]))

        XCTAssertEqual(snapshot.completeText, "helloworld")
        XCTAssertEqual(snapshot.finalText, "hello")
    }

    func testReducerRemovesControlMarkersAndPreservesRepeatedWords() throws {
        var reducer = SonioxTokenReducer()
        let snapshot = try reducer.reduce(SonioxServerMessage(tokens: [
            .init(text: "go", isFinal: true, confidence: 0.2),
            .init(text: "go", isFinal: true, confidence: 0.4),
            .init(text: "<fin>", isFinal: true, confidence: 1),
            .init(text: "<end>", isFinal: true, confidence: 1),
        ]))

        XCTAssertEqual(snapshot.completeText, "gogo")
        XCTAssertEqual(snapshot.confidence, 0.3, accuracy: 0.0001)
        XCTAssertTrue(snapshot.sawFin)
        XCTAssertTrue(snapshot.sawEnd)
    }

    func testReducerConfidenceUsesOnlyTranscriptTokensWithConfidence() throws {
        var reducer = SonioxTokenReducer()
        _ = try reducer.reduce(SonioxServerMessage(tokens: [
            .init(text: "fixed", isFinal: true, confidence: 0.8),
            .init(text: "old", isFinal: false, confidence: 0.2),
        ]))
        let snapshot = try reducer.reduce(SonioxServerMessage(tokens: [
            .init(text: "new", isFinal: false, confidence: 0.4),
            .init(text: "unknown", isFinal: false, confidence: nil),
            .init(text: "<fin>", isFinal: false, confidence: 1),
        ]))

        XCTAssertEqual(snapshot.confidence, 0.6, accuracy: 0.0001)
    }

    func testErrorTypeTableMapsEveryOfficialSlugToOneStableUserCategory() {
        let cases: [(String, SonioxFailureCategory)] = [
            ("unauthenticated", .credential),
            ("temp_api_key_session_expired", .credential),
            ("invalid_request", .configuration),
            ("model_not_available", .configuration),
            ("organization_balance_exhausted", .balance),
            ("organization_monthly_budget_exhausted", .balance),
            ("project_monthly_budget_exhausted", .balance),
            ("limit_exceeded", .limit),
            ("request_timeout", .temporaryService),
            ("max_duration_reached", .temporaryService),
            ("internal_error", .temporaryService),
            ("service_unavailable", .temporaryService),
        ]

        for (errorType, category) in cases {
            XCTAssertEqual(SonioxErrorMapper.category(for: errorType), category, errorType)
        }
    }

    func testUnknownOrMalformedErrorTypeFallsBackToTemporaryServiceWithoutProse() {
        let error = SonioxErrorMapper.error(errorType: "NOT safe!", requestID: "request-42")

        XCTAssertEqual(error.category, .temporaryService)
        XCTAssertEqual(error.diagnosticType, "unknown_error_type")
        XCTAssertEqual(error.requestID, "request-42")
    }

    func testRequestIDIsRetainedOnlyWhenItMatchesTheBoundedSafeCharacterSet() {
        XCTAssertEqual(SonioxErrorMapper.sanitizedRequestID("Request_42-abc"), "Request_42-abc")
        XCTAssertNil(SonioxErrorMapper.sanitizedRequestID("request id"))
        XCTAssertNil(SonioxErrorMapper.sanitizedRequestID(String(repeating: "a", count: 129)))
    }

    func testEverySonioxFailureCategoryMapsToFixedUserFacingTitleAndMessage() {
        let cases: [(SonioxFailureCategory, SonioxUserFacingErrorCopy)] = [
            (.credential, .init(title: "Soniox API Key Required", message: "Check or re-verify the Soniox API key for the selected region in Voice Engine settings.")),
            (.configuration, .init(title: "Soniox Configuration Error", message: "The selected Soniox model or audio configuration is unavailable.")),
            (.balance, .init(title: "Soniox Balance Exhausted", message: "Add balance or increase the project budget in Soniox, then try again.")),
            (.limit, .init(title: "Soniox Usage Limit Reached", message: "The Soniox concurrency or rate limit was reached. Try again shortly.")),
            (.temporaryService, .init(title: "Soniox Temporarily Unavailable", message: "Check the network connection and try again.")),
            (.finalizationTimeout, .init(title: "Soniox Finalization Timed Out", message: "Soniox did not finish the transcription in time. Try again.")),
        ]

        for (category, copy) in cases {
            XCTAssertEqual(SonioxErrorMapper.userFacingCopy(for: category), copy)
        }
    }

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

    func testAllOfficialLanguageCodesResolveFromLocales() {
        let languageCodes = [
            "af", "sq", "ar", "az", "eu", "be", "bn", "bs", "bg", "ca", "zh", "hr",
            "cs", "da", "nl", "en", "et", "fi", "fr", "gl", "de", "el", "gu", "he",
            "hi", "hu", "id", "it", "ja", "kn", "kk", "ko", "lv", "lt", "mk", "ms",
            "ml", "mr", "no", "fa", "pl", "pt", "pa", "ro", "ru", "sr", "sk", "sl",
            "es", "sw", "sv", "tl", "ta", "te", "th", "tr", "uk", "ur", "vi", "cy",
        ]

        for code in languageCodes {
            let localeIdentifier = code == "tl" ? "fil-PH" : "\(code)-ZZ"
            XCTAssertEqual(
                SonioxLanguageCatalog.binding(
                    localeIdentifier: localeIdentifier,
                    mode: .currentInputSourceOnly,
                    region: .global
                ),
                SonioxSessionBinding(languageCode: code, isStrict: true, region: .global),
                "Expected \(localeIdentifier) to resolve to \(code)"
            )
        }
    }
}

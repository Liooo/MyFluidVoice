@testable import FluidVoice_Debug
import XCTest

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

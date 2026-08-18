import Foundation

extension SettingsStore {
    nonisolated enum SonioxLanguageMode: String, Codable, CaseIterable, Identifiable, Sendable {
        case automatic
        case preferCurrentInputSource
        case currentInputSourceOnly

        var id: String { self.rawValue }

        var displayName: String {
            switch self {
            case .automatic: "Automatic"
            case .preferCurrentInputSource: "Prefer Current Input Source"
            case .currentInputSourceOnly: "Current Input Source Only"
            }
        }

        var description: String {
            switch self {
            case .automatic:
                "Automatically detect the spoken language."
            case .preferCurrentInputSource:
                "Use the current input source language when supported, otherwise detect automatically."
            case .currentInputSourceOnly:
                "Use only the current input source language."
            }
        }
    }

    nonisolated enum SonioxRegion: String, Codable, CaseIterable, Identifiable, Sendable {
        case global
        case japan

        var id: String { self.rawValue }

        var displayName: String {
            switch self {
            case .global: "Global"
            case .japan: "Japan"
            }
        }

        var description: String {
            switch self {
            case .global:
                "Use Soniox's global service endpoint."
            case .japan:
                "Requires a Soniox Japan-region project and region-specific API key."
            }
        }

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

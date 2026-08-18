import AppKit
import Carbon
import Foundation

nonisolated struct KeyboardInputSourceSnapshot: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let localizedName: String
    let languages: [String]
}

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

        let scalars = region.unicodeScalars.compactMap { UnicodeScalar($0.value + 0x1F1A5) }
        return String(String.UnicodeScalarView(scalars))
    }

    static func languageCode(for localeIdentifier: String) -> String? {
        let language = Locale(identifier: localeIdentifier).language.languageCode?.identifier
        guard let language, language.count >= 2 else { return nil }
        return language.uppercased()
    }
}

enum KeyboardInputSourceService {
    static func currentInputSource() -> KeyboardInputSourceSnapshot? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return self.snapshot(from: source)
    }

    static func currentInputSourceBadge() -> KeyboardInputSourceBadge? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let snapshot = self.snapshot(from: source)
        else { return nil }

        return self.badge(for: snapshot, nativeIcon: self.nativeIcon(from: source))
    }

    static func badge(
        for inputSource: KeyboardInputSourceSnapshot,
        nativeIcon: NSImage?
    ) -> KeyboardInputSourceBadge? {
        let localeIdentifier = KeyboardInputSourceLocaleResolver.localeIdentifier(for: inputSource)
        let fallbackText = nativeIcon == nil
            ? KeyboardInputSourceBadgeFormatter.flag(for: localeIdentifier)
                ?? KeyboardInputSourceBadgeFormatter.languageCode(for: localeIdentifier)
            : nil
        guard nativeIcon != nil || fallbackText != nil else { return nil }

        return KeyboardInputSourceBadge(
            sourceID: inputSource.id,
            localeIdentifier: localeIdentifier,
            nativeIcon: nativeIcon,
            fallbackText: fallbackText
        )
    }

    static func installedInputSources() -> [KeyboardInputSourceSnapshot] {
        guard let keyboardCategory = kTISCategoryKeyboardInputSource else { return [] }
        let properties: [CFString: Any] = [
            kTISPropertyInputSourceCategory: keyboardCategory,
            kTISPropertyInputSourceIsEnabled: true,
            kTISPropertyInputSourceIsSelectCapable: true,
        ]
        guard let sources = TISCreateInputSourceList(properties as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource]
        else { return [] }

        var snapshotsByID: [String: KeyboardInputSourceSnapshot] = [:]
        for source in sources where self.booleanProperty(kTISPropertyInputSourceIsEnabled, from: source) == true
            && self.booleanProperty(kTISPropertyInputSourceIsSelectCapable, from: source) == true
        {
            guard let snapshot = self.snapshot(from: source) else { continue }
            snapshotsByID[snapshot.id] = snapshot
        }

        return snapshotsByID.values.sorted { lhs, rhs in
            let nameOrder = lhs.localizedName.localizedCaseInsensitiveCompare(rhs.localizedName)
            if nameOrder == .orderedSame {
                return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
            }
            return nameOrder == .orderedAscending
        }
    }

    private static func snapshot(from source: TISInputSource) -> KeyboardInputSourceSnapshot? {
        guard let id = self.stringProperty(kTISPropertyInputSourceID, from: source),
              !id.isEmpty,
              let localizedName = self.stringProperty(kTISPropertyLocalizedName, from: source),
              !localizedName.isEmpty
        else { return nil }

        return KeyboardInputSourceSnapshot(
            id: id,
            localizedName: localizedName,
            languages: self.stringArrayProperty(kTISPropertyInputSourceLanguages, from: source)
        )
    }

    private static func nativeIcon(from source: TISInputSource) -> NSImage? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyIconImageURL) else { return nil }
        let url = Unmanaged<CFURL>.fromOpaque(pointer).takeUnretainedValue() as URL
        return NSImage(contentsOf: url)
    }

    private static func stringProperty(_ key: CFString, from source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func stringArrayProperty(_ key: CFString, from source: TISInputSource) -> [String] {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return [] }
        let values = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue()
        return values as? [String] ?? []
    }

    private static func booleanProperty(_ key: CFString, from source: TISInputSource) -> Bool? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        let value = Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue()
        return CFBooleanGetValue(value)
    }
}

nonisolated enum KeyboardInputSourceLocaleResolver {
    static func localeIdentifier(
        for inputSource: KeyboardInputSourceSnapshot,
        fallbackLocaleIdentifier: String = Locale.current.identifier
    ) -> String {
        if let mappedLocale = self.exactLocalesByInputSourceID[inputSource.id] {
            return mappedLocale
        }

        let normalizedID = inputSource.id.lowercased()
        let isJapaneseInputMethod = normalizedID.contains("kotoeri")
            || normalizedID.contains("google.inputmethod.japanese")
            || normalizedID.contains("justsystems")
            || normalizedID.contains("atok")
        if isJapaneseInputMethod {
            return normalizedID.hasSuffix(".roman") || normalizedID.contains(".roman.")
                ? "en-US"
                : "ja-JP"
        }

        if normalizedID.contains("tcim")
            || normalizedID.contains("traditional")
            || normalizedID.contains("zhuyin")
            || normalizedID.contains("cangjie")
        {
            return "zh-TW"
        }
        if normalizedID.contains("scim")
            || normalizedID.contains("simplified")
            || normalizedID.contains("sogou")
            || normalizedID.contains("baidu")
        {
            return "zh-CN"
        }
        if normalizedID.contains("inputmethod.korean") {
            return "ko-KR"
        }

        for language in inputSource.languages {
            let normalizedLanguage = self.normalizedSpeechLocaleIdentifier(language)
            if !normalizedLanguage.isEmpty {
                return normalizedLanguage
            }
        }

        let normalizedFallback = self.normalizedSpeechLocaleIdentifier(fallbackLocaleIdentifier)
        return normalizedFallback.isEmpty ? "en-US" : normalizedFallback
    }

    private static func normalizedSpeechLocaleIdentifier(_ identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let components = trimmed
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", omittingEmptySubsequences: true)
            .map(String.init)
        guard let languageComponent = components.first else { return "" }

        let language = languageComponent.lowercased()
        if language == "zh" {
            let qualifiers = Set(components.dropFirst().map { $0.lowercased() })
            if !qualifiers.isDisjoint(with: ["hant", "tw", "hk", "mo"]) {
                return "zh-TW"
            }
            return "zh-CN"
        }

        if components.count == 1, let defaultLocale = self.defaultLocalesByLanguage[language] {
            return defaultLocale
        }

        let normalizedComponents = components.enumerated().map { index, component in
            if index == 0 { return component.lowercased() }
            if component.count == 4 {
                return component.prefix(1).uppercased() + component.dropFirst().lowercased()
            }
            if component.count == 2 || component.allSatisfy(\.isNumber) {
                return component.uppercased()
            }
            return component
        }
        return normalizedComponents.joined(separator: "-")
    }

    private static let exactLocalesByInputSourceID: [String: String] = [
        "com.apple.keylayout.US": "en-US",
        "com.apple.keylayout.ABC": "en-US",
        "com.apple.keylayout.USExtended": "en-US",
        "com.apple.keylayout.USInternational-PC": "en-US",
        "com.apple.keylayout.Dvorak": "en-US",
        "com.apple.keylayout.Colemak": "en-US",
        "com.apple.keylayout.British": "en-GB",
        "com.apple.keylayout.Australian": "en-AU",
        "com.apple.keylayout.Canadian": "en-CA",
        "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese": "ja-JP",
        "com.apple.inputmethod.Kotoeri.RomajiTyping.Roman": "en-US",
        "com.apple.inputmethod.Kotoeri.KanaTyping.Japanese": "ja-JP",
        "com.apple.inputmethod.Kotoeri.KanaTyping.Roman": "en-US",
        "com.google.inputmethod.Japanese.base": "ja-JP",
        "com.google.inputmethod.Japanese.Roman": "en-US",
        "com.justsystems.inputmethod.atok33.Japanese": "ja-JP",
        "com.justsystems.inputmethod.atok33.Roman": "en-US",
        "com.justsystems.inputmethod.atok32.Japanese": "ja-JP",
        "com.justsystems.inputmethod.atok32.Roman": "en-US",
        "com.justsystems.inputmethod.atok.Japanese": "ja-JP",
        "com.justsystems.inputmethod.atok.Roman": "en-US",
        "com.apple.inputmethod.SCIM.ITABC": "zh-CN",
        "com.apple.inputmethod.TCIM.Pinyin": "zh-TW",
        "com.apple.inputmethod.TCIM.Zhuyin": "zh-TW",
        "com.apple.inputmethod.Korean.2SetKorean": "ko-KR",
        "com.apple.inputmethod.Korean.3SetKorean": "ko-KR",
        "com.apple.inputmethod.Korean.390Sebulshik": "ko-KR",
        "com.apple.inputmethod.Korean.GongjinCheong": "ko-KR",
        "com.apple.keylayout.German": "de-DE",
        "com.apple.keylayout.Austrian": "de-AT",
        "com.apple.keylayout.SwissGerman": "de-CH",
        "com.apple.keylayout.French": "fr-FR",
        "com.apple.keylayout.CanadianFrench-CSA": "fr-CA",
        "com.apple.keylayout.SwissFrench": "fr-CH",
        "com.apple.keylayout.Spanish": "es-ES",
        "com.apple.keylayout.Spanish-ISO": "es-ES",
        "com.apple.keylayout.LatinAmerican": "es-MX",
        "com.apple.keylayout.Italian": "it-IT",
        "com.apple.keylayout.Italian-Pro": "it-IT",
        "com.apple.keylayout.Portuguese": "pt-PT",
        "com.apple.keylayout.Brazilian": "pt-BR",
        "com.apple.keylayout.Brazilian-Pro": "pt-BR",
        "com.apple.keylayout.Russian": "ru-RU",
        "com.apple.keylayout.RussianWin": "ru-RU",
    ]

    private static let defaultLocalesByLanguage: [String: String] = [
        "ar": "ar-SA",
        "bg": "bg-BG",
        "cs": "cs-CZ",
        "da": "da-DK",
        "de": "de-DE",
        "el": "el-GR",
        "en": "en-US",
        "es": "es-ES",
        "et": "et-EE",
        "fi": "fi-FI",
        "fr": "fr-FR",
        "he": "he-IL",
        "hi": "hi-IN",
        "hr": "hr-HR",
        "hu": "hu-HU",
        "id": "id-ID",
        "it": "it-IT",
        "ja": "ja-JP",
        "ko": "ko-KR",
        "lt": "lt-LT",
        "lv": "lv-LV",
        "ms": "ms-MY",
        "mt": "mt-MT",
        "nb": "nb-NO",
        "nl": "nl-NL",
        "nn": "nn-NO",
        "no": "nb-NO",
        "pl": "pl-PL",
        "pt": "pt-PT",
        "ro": "ro-RO",
        "ru": "ru-RU",
        "sk": "sk-SK",
        "sl": "sl-SI",
        "sv": "sv-SE",
        "th": "th-TH",
        "tr": "tr-TR",
        "uk": "uk-UA",
        "vi": "vi-VN",
    ]
}

enum RecordingSpeechConfigurationResolver {
    static func globalFallbackConfiguration(
        model: SettingsStore.SpeechModel,
        selectedLanguageID: String,
        appleLocaleIdentifier: String,
        cohereLanguage: SettingsStore.CohereLanguage,
        nemotronLanguage: SettingsStore.NemotronLanguage,
        sonioxLanguageMode: SettingsStore.SonioxLanguageMode,
        sonioxRegion: SettingsStore.SonioxRegion
    ) -> RecordingSpeechConfiguration? {
        guard model != .qwen3Asr else { return nil }

        let selectedLocaleIdentifier = self.localeIdentifier(forLanguageID: selectedLanguageID)
        let localeIdentifier: String
        let binding: VoiceEngineLanguageRoute.LanguageBinding?

        switch model {
        case .sonioxV5:
            localeIdentifier = selectedLocaleIdentifier
            binding = .soniox(SonioxLanguageCatalog.binding(
                localeIdentifier: localeIdentifier,
                mode: sonioxLanguageMode,
                region: sonioxRegion
            ))
        case .appleSpeech, .appleSpeechAnalyzer:
            localeIdentifier = appleLocaleIdentifier.replacingOccurrences(of: "_", with: "-")
            binding = .appleSpeech(localeIdentifier: localeIdentifier)
        case .cohereTranscribeSixBit:
            localeIdentifier = self.localeIdentifier(forLanguageID: cohereLanguage.rawValue)
            binding = .cohere(cohereLanguage)
        case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
            localeIdentifier = nemotronLanguage == .auto
                ? selectedLocaleIdentifier
                : self.localeIdentifier(forLanguageID: nemotronLanguage.rawValue)
            binding = .nemotron(nemotronLanguage)
        case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
            localeIdentifier = selectedLocaleIdentifier
            binding = self.languageBinding(for: model, localeIdentifier: localeIdentifier)
        case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime:
            localeIdentifier = selectedLocaleIdentifier
            binding = self.languageBinding(for: model, localeIdentifier: localeIdentifier)
                ?? self.languageBinding(for: model, localeIdentifier: "en-US")
        case .qwen3Asr:
            return nil
        }

        guard let binding else { return nil }
        return RecordingSpeechConfiguration(
            inputSourceID: nil,
            localeIdentifier: localeIdentifier,
            model: model,
            languageBinding: binding
        )
    }

    static func currentDictationFallbackConfiguration(
        settings: SettingsStore = .shared
    ) -> RecordingSpeechConfiguration {
        if let configuration = self.globalFallbackConfiguration(
            model: settings.selectedSpeechModel,
            selectedLanguageID: settings.onboardingSelectedLanguageID,
            appleLocaleIdentifier: settings.selectedAppleSpeechLocale.identifier,
            cohereLanguage: settings.selectedCohereLanguage,
            nemotronLanguage: settings.selectedNemotronLanguage,
            sonioxLanguageMode: settings.sonioxLanguageMode,
            sonioxRegion: settings.sonioxRegion
        ) {
            return configuration
        }

        guard let safeFallback = RecordingSpeechConfiguration(
            inputSourceID: nil,
            localeIdentifier: "en-US",
            model: .parakeetTDT,
            languageBinding: .automatic
        ) else {
            preconditionFailure("Built-in Parakeet fallback configuration must be valid")
        }
        return safeFallback
    }

    static func currentLocalFallbackConfiguration(
        settings: SettingsStore = .shared
    ) -> RecordingSpeechConfiguration {
        if let configuration = self.globalFallbackConfiguration(
            model: settings.localFallbackSpeechModel,
            selectedLanguageID: settings.onboardingSelectedLanguageID,
            appleLocaleIdentifier: settings.selectedAppleSpeechLocale.identifier,
            cohereLanguage: settings.selectedCohereLanguage,
            nemotronLanguage: settings.selectedNemotronLanguage,
            sonioxLanguageMode: settings.sonioxLanguageMode,
            sonioxRegion: settings.sonioxRegion
        ) {
            return configuration
        }

        guard let safeFallback = RecordingSpeechConfiguration(
            inputSourceID: nil,
            localeIdentifier: "en-US",
            model: .parakeetTDT,
            languageBinding: .automatic
        ) else {
            preconditionFailure("Built-in Parakeet fallback configuration must be valid")
        }
        return safeFallback
    }

    static func compatibleModels(
        for inputSource: KeyboardInputSourceSnapshot,
        availableModels: [SettingsStore.SpeechModel] = SettingsStore.SpeechModel.availableModels,
        fallbackLocaleIdentifier: String = Locale.current.identifier
    ) -> [SettingsStore.SpeechModel] {
        let localeIdentifier = KeyboardInputSourceLocaleResolver.localeIdentifier(
            for: inputSource,
            fallbackLocaleIdentifier: fallbackLocaleIdentifier
        )
        return availableModels.filter { model in
            self.languageBinding(for: model, localeIdentifier: localeIdentifier) != nil
        }
    }

    static func resolve(
        inputSource: KeyboardInputSourceSnapshot?,
        assignedModel: SettingsStore.SpeechModel?,
        globalFallback: RecordingSpeechConfiguration,
        sonioxLanguageMode: SettingsStore.SonioxLanguageMode,
        sonioxRegion: SettingsStore.SonioxRegion,
        availableModels: [SettingsStore.SpeechModel] = SettingsStore.SpeechModel.availableModels,
        fallbackLocaleIdentifier: String = Locale.current.identifier
    ) -> RecordingSpeechConfiguration {
        let fallback = self.globalFallback(globalFallback, inputSourceID: inputSource?.id)
        let resolvedModel = assignedModel ?? globalFallback.model
        guard availableModels.contains(resolvedModel) else { return fallback }

        let localeIdentifier = inputSource.map {
            KeyboardInputSourceLocaleResolver.localeIdentifier(
                for: $0,
                fallbackLocaleIdentifier: fallbackLocaleIdentifier
            )
        } ?? fallback.localeIdentifier
        if resolvedModel == .sonioxV5 {
            return RecordingSpeechConfiguration(
                inputSourceID: inputSource?.id,
                localeIdentifier: localeIdentifier,
                model: resolvedModel,
                languageBinding: .soniox(SonioxLanguageCatalog.binding(
                    localeIdentifier: localeIdentifier,
                    mode: sonioxLanguageMode,
                    region: sonioxRegion
                ))
            ) ?? fallback
        }

        guard let inputSource, let assignedModel,
              let binding = self.languageBinding(for: assignedModel, localeIdentifier: localeIdentifier),
              let configuration = RecordingSpeechConfiguration(
                  inputSourceID: inputSource.id,
                  localeIdentifier: localeIdentifier,
                  model: assignedModel,
                  languageBinding: binding
              )
        else { return fallback }
        return configuration
    }

    static func languageBinding(
        for model: SettingsStore.SpeechModel,
        localeIdentifier: String
    ) -> VoiceEngineLanguageRoute.LanguageBinding? {
        let normalizedLocale = localeIdentifier.replacingOccurrences(of: "_", with: "-")
        guard let languageCode = normalizedLocale
            .split(separator: "-", maxSplits: 1)
            .first
            .map({ String($0).lowercased() }),
            !languageCode.isEmpty
        else { return nil }

        switch model {
        case .sonioxV5:
            return .soniox(SonioxLanguageCatalog.binding(
                localeIdentifier: normalizedLocale,
                mode: .currentInputSourceOnly,
                region: .global
            ))
        case .parakeetTDT:
            return self.parakeetTDTLanguageCodes.contains(languageCode) ? .automatic : nil
        case .parakeetTDTv2, .parakeetRealtime:
            return languageCode == "en" ? .automatic : nil
        case .qwen3Asr:
            return self.qwenLanguageCodes.contains(languageCode) ? .automatic : nil
        case .cohereTranscribeSixBit:
            return SettingsStore.CohereLanguage(rawValue: languageCode).map(
                VoiceEngineLanguageRoute.LanguageBinding.cohere
            )
        case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
            return self.nemotronLanguage(
                localeIdentifier: normalizedLocale,
                languageCode: languageCode
            ).map(VoiceEngineLanguageRoute.LanguageBinding.nemotron)
        case .appleSpeech:
            guard self.appleSpeechLanguageCodes.contains(languageCode) else { return nil }
            return .appleSpeech(localeIdentifier: normalizedLocale)
        case .appleSpeechAnalyzer:
            guard self.appleSpeechAnalyzerLanguageCodes.contains(languageCode) else { return nil }
            return .appleSpeech(localeIdentifier: normalizedLocale)
        case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
            let engineLanguageCode = switch languageCode {
            case "nb": "no"
            case "fil": "tl"
            case "jv": "jw"
            default: languageCode
            }
            return VoiceEngineLanguageCatalog.routes(
                forLanguageID: engineLanguageCode,
                availableModels: [.whisperSmall]
            ).first?.binding
        }
    }

    private static func globalFallback(
        _ fallback: RecordingSpeechConfiguration,
        inputSourceID: String?
    ) -> RecordingSpeechConfiguration {
        RecordingSpeechConfiguration(
            inputSourceID: inputSourceID,
            localeIdentifier: fallback.localeIdentifier,
            model: fallback.model,
            languageBinding: fallback.languageBinding
        ) ?? fallback
    }

    private static func localeIdentifier(forLanguageID languageID: String) -> String {
        KeyboardInputSourceLocaleResolver.localeIdentifier(
            for: KeyboardInputSourceSnapshot(
                id: "com.myfluidvoice.language.\(languageID)",
                localizedName: languageID,
                languages: [languageID]
            ),
            fallbackLocaleIdentifier: "en-US"
        )
    }

    private static func nemotronLanguage(
        localeIdentifier: String,
        languageCode: String
    ) -> SettingsStore.NemotronLanguage? {
        let lowercasedLocale = localeIdentifier.lowercased()
        if languageCode == "zh",
           lowercasedLocale.contains("-tw")
            || lowercasedLocale.contains("-hk")
            || lowercasedLocale.contains("-mo")
            || lowercasedLocale.contains("-hant")
        {
            return nil
        }

        if let exact = SettingsStore.NemotronLanguage.supportedLanguage(rawValue: localeIdentifier) {
            return exact
        }
        if let language = SettingsStore.NemotronLanguage.supportedLanguage(rawValue: languageCode) {
            return language
        }
        return SettingsStore.NemotronLanguage.allCases.first { candidate in
            candidate.rawValue
                .split(separator: "-", maxSplits: 1)
                .first
                .map({ String($0).lowercased() }) == languageCode
        }
    }

    private static let parakeetTDTLanguageCodes: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]

    private static let qwenLanguageCodes: Set<String> = [
        "zh", "en", "yue", "ar", "de", "fr", "es", "pt", "id", "it", "ko", "ru", "th",
        "vi", "ja", "tr", "hi", "ms", "nl", "sv", "da", "fi", "pl", "cs", "fil", "fa",
        "el", "hu", "mk", "ro",
    ]

    private static let appleSpeechAnalyzerLanguageCodes: Set<String> = [
        "de", "en", "es", "fr", "it", "ja", "ko", "pt", "zh",
    ]

    private static let appleSpeechLanguageCodes: Set<String> = [
        "ar", "ca", "cs", "da", "de", "el", "en", "es", "fi", "fr", "he", "hi", "hr",
        "hu", "id", "it", "ja", "ko", "ms", "nl", "no", "nb", "pl", "pt", "ro", "ru",
        "sk", "sv", "th", "tr", "uk", "vi", "zh",
    ]
}

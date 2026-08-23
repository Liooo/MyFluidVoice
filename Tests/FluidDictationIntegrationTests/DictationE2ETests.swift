import AppKit
@testable import FluidVoice_Debug
import Foundation
import XCTest

// Task-specific integration coverage is intentionally kept in this registered suite.
// swiftlint:disable file_length
@MainActor
final class DictationE2ETests: XCTestCase {
    private let dictationPromptProfilesKey = "DictationPromptProfiles"
    private let appPromptBindingsKey = "AppPromptBindings"
    private let selectedDictationPromptIDKey = "SelectedDictationPromptID"
    private let selectedEditPromptIDKey = "SelectedEditPromptID"
    private let dictationPromptOffKey = "DictationPromptOff"
    private let editPromptOffKey = "EditPromptOff"
    private let defaultDictationPromptOverrideKey = "DefaultDictationPromptOverride"
    private let defaultEditPromptOverrideKey = "DefaultEditPromptOverride"
    private let dictationPromptRoutingScopeKey = "DictationPromptRoutingScope"
    private let savedProvidersKey = "SavedProviders"
    private let selectedProviderIDKey = "SelectedProviderID"
    private let selectedAIModelKey = "SelectedAIModel"
    private let availableModelsByProviderKey = "AvailableModelsByProvider"
    private let selectedModelByProviderKey = "SelectedModelByProvider"
    private let dictationPromptConfigurationsKey = "DictationPromptConfigurations"
    private let customDictionaryEntriesKey = "CustomDictionaryEntries"
    private let autoConvertPunctuationEnabledKey = "AutoConvertPunctuationEnabled"
    private let literalDictationFormattingEnabledKey = "LiteralDictationFormattingEnabled"
    private let punctuationDictionaryPrefixKey = "PunctuationDictionaryPrefix"
    private let punctuationDictionaryRulesKey = "PunctuationDictionaryRules"
    private let commandModeLinkedToGlobalKey = "CommandModeLinkedToGlobal"
    private let commandModeSelectedProviderIDKey = "CommandModeSelectedProviderID"
    private let commandModeSelectedModelKey = "CommandModeSelectedModel"
    private let rewriteModeSelectedProviderIDKey = "RewriteModeSelectedProviderID"
    private let rewriteModeSelectedModelKey = "RewriteModeSelectedModel"
    private var privateAISelectedModelIDKey: String {
        PrivateAIProviderFeature.shared.selectedModelDefaultsKey
    }

    private var privateAILocalModelPathKey: String {
        PrivateAIProviderFeature.shared.localModelPathDefaultsKey
    }

    private var privateAIPrefixKVCacheEnabledKey: String {
        PrivateAIProviderFeature.shared.prefixCacheDefaultsKey
    }

    private var privateAIBoostEnabledKey: String {
        PrivateAIProviderFeature.shared.boostDefaultsKey
    }

    private let privateAIContextTokenLimitKey = "PrivateAIProviderContextTokenLimit"
    private let privateAIContextDefaultMigratedTo4KKey = "PrivateAIProviderContextDefaultMigratedTo4K"

    private let verifiedProviderFingerprintsKey = "VerifiedProviderFingerprints"

    private var punctuationFormattingDefaultsKeys: [String] {
        [
            self.autoConvertPunctuationEnabledKey,
            self.punctuationDictionaryPrefixKey,
            self.punctuationDictionaryRulesKey,
        ]
    }

    func testTranscriptionHistoryEntryClipboardTextPrefersProcessedText() {
        let entry = TranscriptionHistoryEntry(
            rawText: " raw transcript ",
            processedText: " processed transcript ",
            appName: "Notes",
            windowTitle: "Draft",
            wasAIProcessed: true
        )

        XCTAssertEqual(entry.clipboardText, "processed transcript")
    }

    func testTranscriptionHistoryEntryClipboardTextFallsBackToRawText() {
        let entry = TranscriptionHistoryEntry(
            rawText: " raw transcript ",
            processedText: "   ",
            appName: "Notes",
            windowTitle: "Draft",
            wasAIProcessed: false
        )

        XCTAssertEqual(entry.clipboardText, "raw transcript")
    }

    func testTranscriptionHistoryEntryClipboardTextSkipsEmptyText() {
        let entry = TranscriptionHistoryEntry(
            rawText: "   ",
            processedText: "   ",
            appName: "Notes",
            windowTitle: "Draft",
            wasAIProcessed: false
        )

        XCTAssertNil(entry.clipboardText)
    }

    func testDictionaryTransferDocument_encodesSimpleUserFormat() throws {
        let document = DictionaryTransferDocument(
            replacements: [
                DictionaryTransferReplacement(from: ["fluid voice", "fluid boys"], to: "FluidVoice"),
            ],
            customWords: ["FluidVoice", "GEMBA-E"]
        )

        let data = try DictionaryTransferService.shared.encode(document)
        let json = String(data: data, encoding: .utf8) ?? ""
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let replacements = try XCTUnwrap(root["replacements"] as? [[String: Any]])
        let firstReplacement = try XCTUnwrap(replacements.first)

        XCTAssertEqual(firstReplacement["from"] as? [String], ["fluid voice", "fluid boys"])
        XCTAssertEqual(firstReplacement["to"] as? String, "FluidVoice")
        XCTAssertEqual(root["customWords"] as? [String], ["FluidVoice", "GEMBA-E"])
        XCTAssertFalse(json.contains("\"triggers\""))
        XCTAssertFalse(json.contains("\"replacement\""))
        XCTAssertFalse(json.contains("\"aliases\""))
    }

    func testDictionaryTransferImport_replaceMapsSimpleFormatToStores() throws {
        let document = DictionaryTransferDocument(
            replacements: [
                DictionaryTransferReplacement(from: [" Fluid Voice ", "FLUID BOYS", ""], to: " FluidVoice "),
            ],
            customWords: [" FluidVoice ", "fluidvoice", " Barath "]
        )
        let existingReplacement = SettingsStore.CustomDictionaryEntry(triggers: ["old"], replacement: "Old")
        let existingWord = ParakeetVocabularyStore.VocabularyConfig.Term(text: "OldWord", weight: 13.0)

        let state = try DictionaryTransferService.importState(
            document: document,
            mode: .replace,
            currentReplacements: [existingReplacement],
            currentCustomWords: [existingWord]
        )

        XCTAssertEqual(state.replacements.count, 1)
        XCTAssertEqual(state.replacements.first?.triggers, ["fluid voice", "fluid boys"])
        XCTAssertEqual(state.replacements.first?.replacement, "FluidVoice")
        XCTAssertEqual(state.customWords.map(\.text), ["FluidVoice", "Barath"])
        XCTAssertEqual(state.customWords.map(\.weight), [10.0, 10.0])
        XCTAssertEqual(state.customWords.map(\.aliases), [[], []])
    }

    func testDictionaryTransferImport_mergeDedupesAndMovesDuplicateTriggers() throws {
        let oldReplacement = SettingsStore.CustomDictionaryEntry(
            triggers: ["fluid voice", "old trigger"],
            replacement: "Old"
        )
        let existingReplacement = SettingsStore.CustomDictionaryEntry(
            triggers: ["fluid boys"],
            replacement: "FluidVoice"
        )
        let existingWord = ParakeetVocabularyStore.VocabularyConfig.Term(
            text: "Barath",
            weight: 13.0,
            aliases: ["barath w"]
        )
        let document = DictionaryTransferDocument(
            replacements: [
                DictionaryTransferReplacement(from: ["fluid voice", "fluid boys"], to: "FluidVoice"),
            ],
            customWords: ["barath", "GEMBA-E"]
        )

        let state = try DictionaryTransferService.importState(
            document: document,
            mode: .merge,
            currentReplacements: [oldReplacement, existingReplacement],
            currentCustomWords: [existingWord]
        )

        let fluidVoiceEntry = try XCTUnwrap(state.replacements.first { $0.replacement == "FluidVoice" })
        let oldEntry = try XCTUnwrap(state.replacements.first { $0.replacement == "Old" })
        let barathTerm = try XCTUnwrap(state.customWords.first { $0.text == "Barath" })
        let gembaeTerm = try XCTUnwrap(state.customWords.first { $0.text == "GEMBA-E" })

        XCTAssertEqual(Set(fluidVoiceEntry.triggers), Set(["fluid voice", "fluid boys"]))
        XCTAssertEqual(oldEntry.triggers, ["old trigger"])
        XCTAssertEqual(barathTerm.weight, 13.0)
        XCTAssertEqual(barathTerm.aliases, ["barath w"])
        XCTAssertEqual(gembaeTerm.weight, 10.0)
    }

    func testDictionaryTransferImport_acceptsAppStyleReplacementKeysAndSingleFromValue() throws {
        let json = """
        {
          "replacements": [
            {
              "from": "fluid voice",
              "to": "FluidVoice"
            },
            {
              "triggers": ["gemba e"],
              "replacement": "GEMBA-E"
            }
          ]
        }
        """

        let document = try DictionaryTransferService.shared.decode(Data(json.utf8))
        let state = try DictionaryTransferService.importState(
            document: document,
            mode: .replace,
            currentReplacements: [],
            currentCustomWords: []
        )

        XCTAssertEqual(state.replacements.map(\.triggers), [["fluid voice"], ["gemba e"]])
        XCTAssertEqual(state.replacements.map(\.replacement), ["FluidVoice", "GEMBA-E"])
    }

    func testDictionaryTransferImport_acceptsLocalAPIReplacementItemsResponse() throws {
        let json = """
        {
          "count": 1,
          "items": [
            {
              "triggers": ["fluid voice"],
              "replacement": "FluidVoice"
            }
          ]
        }
        """

        let document = try DictionaryTransferService.shared.decode(Data(json.utf8))
        let state = try DictionaryTransferService.importState(
            document: document,
            mode: .replace,
            currentReplacements: [],
            currentCustomWords: []
        )

        XCTAssertEqual(state.replacements.first?.triggers, ["fluid voice"])
        XCTAssertEqual(state.replacements.first?.replacement, "FluidVoice")
        XCTAssertEqual(state.customWords.count, 0)
    }

    func testDictionaryTransferImportFeedsActualReplacementPath() throws {
        defer { ASRService.invalidateDictionaryCache() }
        let document = DictionaryTransferDocument(
            replacements: [
                DictionaryTransferReplacement(from: ["fluid voice"], to: "FluidVoice"),
            ],
            customWords: []
        )
        let state = try DictionaryTransferService.importState(
            document: document,
            mode: .replace,
            currentReplacements: [],
            currentCustomWords: []
        )

        self.withRestoredDefaults(keys: [self.customDictionaryEntriesKey]) {
            SettingsStore.shared.customDictionaryEntries = state.replacements
            ASRService.invalidateDictionaryCache()

            XCTAssertEqual(
                ASRService.applyCustomDictionary("I use fluid voice daily."),
                "I use FluidVoice daily."
            )
        }
    }

    func testCustomDictionaryReplacementTreatsReplacementTextLiterally() {
        defer { ASRService.invalidateDictionaryCache() }
        let entry = SettingsStore.CustomDictionaryEntry(
            triggers: ["dollar path"],
            replacement: #"$5 \path"#
        )

        self.withRestoredDefaults(keys: [self.customDictionaryEntriesKey]) {
            SettingsStore.shared.customDictionaryEntries = [entry]
            ASRService.invalidateDictionaryCache()

            XCTAssertEqual(
                ASRService.applyCustomDictionary("Use dollar path now."),
                #"Use $5 \path now."#
            )
        }
    }

    func testPronunciationDictionaryLabelsUseLastDuplicateEntry() {
        let id = UUID()
        let labels = FluidAudioProvider.dictionaryLabels(from: [
            SettingsStore.CustomDictionaryEntry(id: id, triggers: ["old"], replacement: "Old"),
            SettingsStore.CustomDictionaryEntry(id: id, triggers: ["new"], replacement: "New"),
        ])

        XCTAssertEqual(labels, [id: "New"])
    }

    func testCustomDictionaryReplacementMatchesPunctuationTriggers() {
        defer { ASRService.invalidateDictionaryCache() }
        let entry = SettingsStore.CustomDictionaryEntry(
            triggers: [",,", ","],
            replacement: ","
        )

        self.withRestoredDefaults(keys: [self.customDictionaryEntriesKey]) {
            SettingsStore.shared.customDictionaryEntries = [entry]
            ASRService.invalidateDictionaryCache()

            XCTAssertEqual(
                ASRService.applyCustomDictionary("Hello,, world."),
                "Hello, world."
            )
            XCTAssertEqual(
                ASRService.applyCustomDictionary("Hello, world."),
                "Hello, world."
            )
        }
    }

    func testSlashCommandFormattingLeavesNonCommandSlashUsageAlone() {
        let text = "Use 1/2 and and/or. Open src slash services. Go to https slash slash example dot com. Slash and burn."

        XCTAssertEqual(
            ASRService.applySlashCommandFormatting(text),
            text
        )
    }

    func testLiteralFormattingCanBeDisabled() {
        self.withRestoredDefaults(keys: [self.literalDictationFormattingEnabledKey]) {
            UserDefaults.standard.removeObject(forKey: self.literalDictationFormattingEnabledKey)
            XCTAssertFalse(SettingsStore.shared.literalDictationFormattingEnabled)

            UserDefaults.standard.set(false, forKey: self.literalDictationFormattingEnabledKey)

            XCTAssertEqual(ASRService.applySlashCommandFormatting("slash compact"), "slash compact")
            XCTAssertEqual(ASRService.applyMentionFormatting("mention Paul"), "mention Paul")
            XCTAssertEqual(
                ASRService.makeDictationLiteralOutputPlan(
                    for: "/compact ",
                    appName: "Codex",
                    bundleID: "com.openai.codex"
                ).plainText,
                "/compact "
            )
        }
    }

    func testMentionFormattingLeavesProseAlone() {
        let text = "I am at the store. Meet me at lunch. I am at Paul. Look at Paul's message."

        XCTAssertEqual(
            ASRService.applyMentionFormatting(text, appName: "Slack", bundleID: "com.tinyspeck.slackmacgap"),
            text
        )
    }

    func testMentionOutputPlanDoesNotAutoConfirmAutocomplete() {
        let plan = ASRService.makeDictationLiteralOutputPlan(
            for: "@Paul can you check this",
            appName: "Slack",
            bundleID: "com.tinyspeck.slackmacgap"
        )

        XCTAssertEqual(plan.steps, [.text("@Paul can you check this")])
        XCTAssertEqual(plan.plainText, "@Paul can you check this")
    }

    func testMentionOutputPlanStaysPlainOutsideMentionApps() {
        let text = "@Paul can you check this"

        XCTAssertEqual(
            ASRService.makeDictationLiteralOutputPlan(
                for: text,
                appName: "Notes",
                bundleID: "com.apple.Notes"
            ).steps,
            [.text(text)]
        )
    }

    func testSpokenPunctuationFormattingRequiresDictionaryPrefix() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            UserDefaults.standard.set(true, forKey: self.autoConvertPunctuationEnabledKey)

            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting(
                    "Hello literal comma world literal question mark literal open paren yes literal close paren literal quote done literal quote"
                ),
                "Hello, world? (yes) \"done\""
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("Hello comma world question mark"),
                "Hello comma world question mark"
            )
        }
    }

    func testSpokenPunctuationFormattingConvertsCodeAndContactPunctuationWithPrefix() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            UserDefaults.standard.set(true, forKey: self.autoConvertPunctuationEnabledKey)

            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting(
                    "email literal at the rate example literal dot com literal slash help literal underscore me"
                ),
                "email@example.com/help_me"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting(
                    "email literal at sign example literal dot com",
                    appName: "Codex",
                    bundleID: "com.openai.codex"
                ),
                "email@example.com"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("email at sign example"),
                "email at sign example"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("x literal hyphen ray costs 50 literal percent"),
                "x-ray costs 50%"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("a literal plus b literal equals c"),
                "a + b = c"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("plus equal percent"),
                "plus equal percent"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("literal plus literal equal 50 literal percent"),
                "+ = 50%"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("plus I need the normal word"),
                "plus I need the normal word"
            )
        }
    }

    func testSpokenPunctuationFormattingKeepsBareDotInProse() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            UserDefaults.standard.set(true, forKey: self.autoConvertPunctuationEnabledKey)

            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("the polka dot dress"),
                "the polka dot dress"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("example literal dot com"),
                "example.com"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("version 1 literal dot 2"),
                "version 1.2"
            )
        }
    }

    func testSpokenPunctuationFormattingCleansGeneratedCommaNoiseWithPrefix() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            UserDefaults.standard.set(true, forKey: self.autoConvertPunctuationEnabledKey)

            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("literal hyphen literal comma literal hyphen literal comma literal hyphen"),
                "---"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("50 literal comma literal percent"),
                "50%"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("literal open bracket literal comma literal close bracket"),
                "[]"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("literal open paren literal comma literal close paren"),
                "()"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("literal question mark literal comma literal exclamation mark"),
                "?!"
            )
        }
    }

    func testSpokenPunctuationFormattingPreservesExistingCommasNearSymbols() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            UserDefaults.standard.set(true, forKey: self.autoConvertPunctuationEnabledKey)

            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("Thanks, @Sam"),
                "Thanks, @Sam"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("Use C++, now"),
                "Use C++, now"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("-,-,-"),
                "-,-,-"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("50, %"),
                "50, %"
            )
        }
    }

    func testSpokenPunctuationFormattingRespectsSetting() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            UserDefaults.standard.set(false, forKey: self.autoConvertPunctuationEnabledKey)

            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("Hello literal comma world literal question mark"),
                "Hello literal comma world literal question mark"
            )
        }
    }

    func testSpokenPunctuationFormattingUsesCustomPrefixAndRules() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            let settings = SettingsStore.shared
            UserDefaults.standard.set(true, forKey: self.autoConvertPunctuationEnabledKey)
            settings.punctuationDictionaryPrefix = "type"
            settings.punctuationDictionaryRules = [
                SettingsStore.PunctuationDictionaryRule(
                    aliases: ["right arrow", "arrow"],
                    symbol: "->"
                ),
            ]

            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("type right arrow"),
                "->"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("literal right arrow"),
                "literal right arrow"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("type comma"),
                "type comma"
            )
        }
    }

    func testSpokenPunctuationFormattingUsesEditedRules() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            let settings = SettingsStore.shared
            UserDefaults.standard.set(true, forKey: self.autoConvertPunctuationEnabledKey)
            settings.punctuationDictionaryRules = [
                SettingsStore.PunctuationDictionaryRule(
                    aliases: ["full stop"],
                    symbol: "."
                ),
            ]

            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("literal full stop"),
                "."
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("literal period"),
                "literal period"
            )
        }
    }

    func testTerminalLiteralAutocompleteSpacingLeavesNonAutocompleteTextAlone() {
        XCTAssertEqual(
            ASRService.applyTerminalLiteralAutocompleteSpacing(
                "/model ",
                appName: "Notes",
                bundleID: "com.apple.Notes"
            ),
            "/model "
        )
        XCTAssertEqual(
            ASRService.applyTerminalLiteralAutocompleteSpacing(
                "Run /status please ",
                appName: "Codex",
                bundleID: "com.openai.codex"
            ),
            "Run /status please "
        )
        XCTAssertEqual(
            ASRService.applyTerminalLiteralAutocompleteSpacing(
                "@Paul can you check this ",
                appName: "Slack",
                bundleID: "com.tinyspeck.slackmacgap"
            ),
            "@Paul can you check this "
        )
    }

    func testSlashCommandOutputPlanDoesNotAutoConfirmAutocomplete() {
        XCTAssertEqual(
            ASRService.makeDictationLiteralOutputPlan(
                for: "/goal update the plan",
                appName: "Codex",
                bundleID: "com.openai.codex"
            ).steps,
            [.text("/goal update the plan")]
        )
        XCTAssertEqual(
            ASRService.makeDictationLiteralOutputPlan(
                for: "Run /status please",
                appName: "Codex",
                bundleID: "com.openai.codex"
            ).steps,
            [.text("Run /status please")]
        )
    }

    func testDictionaryTrainingNormalizesSamplesAndIgnoresIntendedText() {
        let triggers = CustomDictionaryTrainingMerge.normalizedTriggers(
            from: [" Fluid Voice. ", "FluidVoice", "fluid voice", " "],
            intendedReplacement: "FluidVoice"
        )

        XCTAssertEqual(triggers, ["fluid voice"])
    }

    func testDictionaryTrainingMergeDedupesAndMovesDuplicateTriggers() {
        let oldReplacement = SettingsStore.CustomDictionaryEntry(
            triggers: ["Fluid Voice.", "old trigger"],
            replacement: "Old"
        )
        let existingReplacement = SettingsStore.CustomDictionaryEntry(
            triggers: ["fluid boys"],
            replacement: "FluidVoice"
        )

        let entries = CustomDictionaryTrainingMerge.mergedEntries(
            current: [existingReplacement, oldReplacement],
            replacement: " fluidvoice ",
            triggers: ["Fluid Voice.", "fluid boys", "FluidVoice", ""]
        )

        let fluidVoiceEntry = entries.first { $0.replacement == "FluidVoice" }
        let oldEntry = entries.first { $0.replacement == "Old" }

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.replacement), ["FluidVoice", "Old"])
        XCTAssertEqual(Set(fluidVoiceEntry?.triggers ?? []), Set(["fluid voice", "fluid boys"]))
        XCTAssertEqual(oldEntry?.triggers, ["old trigger"])
    }

    func testDictionaryTrainingNewReplacementPrependsEntry() {
        let existingReplacement = SettingsStore.CustomDictionaryEntry(
            triggers: ["existing trigger"],
            replacement: "Existing"
        )

        let entries = CustomDictionaryTrainingMerge.mergedEntries(
            current: [existingReplacement],
            replacement: "FluidVoice",
            triggers: ["fluid voice"]
        )

        XCTAssertEqual(entries.map(\.replacement), ["FluidVoice", "Existing"])
        XCTAssertEqual(entries.first?.triggers, ["fluid voice"])
    }

    func testManualDictionaryEntryParsesCommaSeparatedVariants() {
        XCTAssertEqual(
            CustomDictionaryManualEntry.normalizedDraftTriggers("fluid voice, fluid boys, fluid voice"),
            ["fluid voice", "fluid boys"]
        )
    }

    func testManualDictionaryEntryPreservesLiteralCommas() {
        XCTAssertEqual(CustomDictionaryManualEntry.normalizedDraftTriggers(","), [","])
        XCTAssertEqual(CustomDictionaryManualEntry.normalizedDraftTriggers(",,"), [",,"])
    }

    func testAutomaticDictionaryCorrectionDetectsEditedWordInsideDictation() {
        let before = "Notes: I met Barad yesterday."
        let after = "Notes: I met Barath yesterday."
        let insertedRange = (before as NSString).range(of: "I met Barad yesterday.")

        let candidate = AutomaticDictionaryCorrectionDetector.candidate(
            before: before,
            after: after,
            insertedRange: insertedRange
        )

        XCTAssertEqual(candidate?.heardText, "Barad")
        XCTAssertEqual(candidate?.correctedText, "Barath")
    }

    func testAutomaticDictionaryCorrectionDetectsInsertionOnlySpellingFix() {
        let before = "Barat joined the call"
        let after = "Barath joined the call"
        let insertedRange = NSRange(location: 0, length: (before as NSString).length)

        let candidate = AutomaticDictionaryCorrectionDetector.candidate(
            before: before,
            after: after,
            insertedRange: insertedRange
        )

        XCTAssertEqual(candidate?.heardText, "Barat")
        XCTAssertEqual(candidate?.correctedText, "Barath")
    }

    func testAutomaticDictionaryCorrectionDetectsInsertionAtDictationEnd() {
        let before = "Barat"
        let after = "Barath"
        let insertedRange = NSRange(location: 0, length: (before as NSString).length)
        let change = AutomaticDictionaryCorrectionDetector.textChange(before: before, after: after)

        XCTAssertNotNil(change)
        if let change {
            XCTAssertTrue(AutomaticDictionaryCorrectionDetector.isWordContinuationAtInsertedRangeEnd(
                change,
                after: after,
                insertedRange: insertedRange
            ))
        }
        let candidate = AutomaticDictionaryCorrectionDetector.candidate(
            before: before,
            after: after,
            insertedRange: insertedRange,
            allowsInsertionAtEnd: true
        )
        XCTAssertEqual(candidate?.heardText, "Barat")
        XCTAssertEqual(candidate?.correctedText, "Barath")
    }

    func testAutomaticDictionaryCorrectionRejectsNewWordAtDictationEnd() {
        let before = "FluidVoice works"
        let after = "FluidVoice works well"
        let insertedRange = NSRange(location: 0, length: (before as NSString).length)
        let change = AutomaticDictionaryCorrectionDetector.textChange(before: before, after: after)

        XCTAssertNotNil(change)
        if let change {
            XCTAssertFalse(AutomaticDictionaryCorrectionDetector.isWordContinuationAtInsertedRangeEnd(
                change,
                after: after,
                insertedRange: insertedRange
            ))
        }
    }

    func testPronunciationReplacementPreservesPunctuationAndSpacing() {
        let replacements = [
            FluidAudioProvider.PronunciationTextReplacement(wordRange: 1...1, label: "Barath"),
        ]

        XCTAssertEqual(
            FluidAudioProvider.applyingPronunciationReplacements(
                to: "Hi,  Barad! How are you?",
                wordTexts: ["Hi,", "Barad!", "How", "are", "you?"],
                replacements: replacements
            ),
            "Hi,  Barath! How are you?"
        )
    }

    func testPronunciationStoreRejectsInconsistentEnrollments() async {
        let store = PronunciationDictionaryStore()
        let enrollments = [
            PronunciationEnrollmentCapture(values: [1, 2], sourceFrameCount: 1, modelKey: "model-a"),
            PronunciationEnrollmentCapture(values: [1], sourceFrameCount: 1, modelKey: "model-b"),
        ]

        do {
            try await store.upsert(
                dictionaryEntryID: UUID(),
                label: "Barath",
                modelKey: "model-a",
                enrollments: enrollments
            )
            XCTFail("Expected inconsistent enrollment validation to fail")
        } catch {
            XCTAssertEqual(error as? PronunciationDictionaryStoreError, .inconsistentEnrollment)
        }
    }

    func testPronunciationStoreRetainsPriorEnrollmentsWhenRetrained() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PronunciationStore-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = PronunciationDictionaryStore(fileURL: fileURL)
        let entryID = UUID()

        let initialEnrollments = (0..<8).map { value in
            PronunciationEnrollmentCapture(
                values: [Float(value), Float(value)],
                sourceFrameCount: 1,
                modelKey: "model-a"
            )
        }
        let retrainedEnrollments = (8..<13).map { value in
            PronunciationEnrollmentCapture(
                values: [Float(value), Float(value)],
                sourceFrameCount: 1,
                modelKey: "model-a"
            )
        }

        try await store.upsert(
            dictionaryEntryID: entryID,
            label: "Barath",
            modelKey: "model-a",
            enrollments: initialEnrollments
        )
        try await store.upsert(
            dictionaryEntryID: entryID,
            label: "Barath",
            modelKey: "model-a",
            enrollments: retrainedEnrollments
        )

        let profiles = await store.profiles(modelKey: "model-a")
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.enrollments.compactMap(\.values.first), (3..<13).map { Float($0) })
    }

    func testPronunciationStoreRestoreRejectsMalformedProfiles() async {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PronunciationStore-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = PronunciationDictionaryStore(fileURL: fileURL)
        let malformedProfile = PronunciationDictionaryProfile(
            dictionaryEntryID: UUID(),
            label: "Barath",
            modelKey: "model-a",
            hiddenSize: 2,
            enrollments: [PronunciationEnrollmentCapture(values: [1], sourceFrameCount: 1, modelKey: "model-a")]
        )

        do {
            try await store.replaceAllProfiles([malformedProfile])
            XCTFail("Expected malformed profile validation to fail")
        } catch {
            XCTAssertEqual(error as? PronunciationDictionaryStoreError, .inconsistentEnrollment)
        }
    }

    func testPronunciationProfileEditPolicyDiscardsProfileWhenMeaningChanges() {
        XCTAssertTrue(
            PronunciationProfileEditPolicy.shouldDiscardProfile(
                previousReplacement: "Barath",
                updatedReplacement: "FluidVoice"
            )
        )
        XCTAssertFalse(
            PronunciationProfileEditPolicy.shouldDiscardProfile(
                previousReplacement: "Barath",
                updatedReplacement: "BARATH"
            )
        )
    }

    func testPronunciationMatchingRequiresSupportedAppleSiliconModel() {
        #if arch(arm64)
        XCTAssertTrue(SettingsStore.SpeechModel.parakeetTDT.supportsPronunciationMatching)
        XCTAssertTrue(SettingsStore.SpeechModel.parakeetTDTv2.supportsPronunciationMatching)
        #else
        XCTAssertFalse(SettingsStore.SpeechModel.parakeetTDT.supportsPronunciationMatching)
        XCTAssertFalse(SettingsStore.SpeechModel.parakeetTDTv2.supportsPronunciationMatching)
        #endif
        XCTAssertFalse(SettingsStore.SpeechModel.whisperLargeTurbo.supportsPronunciationMatching)
        XCTAssertFalse(SettingsStore.SpeechModel.cohereTranscribeSixBit.supportsPronunciationMatching)
    }

    func testDictionaryTrainingAudioCursorResetsAfterBufferGenerationChange() {
        var cursor = DictionaryTrainingAudioCursor(generation: 4)
        cursor.consume(1600)
        cursor.synchronize(generation: 4)
        XCTAssertEqual(cursor.sampleOffset, 1600)

        cursor.synchronize(generation: 5)
        XCTAssertEqual(cursor.sampleOffset, 0)
    }

    func testProgressiveDownloaderRetainsFileByMovingIt() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluidVoiceDownloadSource-\(UUID().uuidString)")
        try Data([1, 2, 3]).write(to: source)
        let retained = try ProgressiveFileDownloader.retainDownloadedFile(at: source)
        defer { try? FileManager.default.removeItem(at: retained) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: retained), Data([1, 2, 3]))
    }

    func testAutomaticDictionaryCorrectionIgnoresTypingAfterDictation() {
        let before = "FluidVoice works"
        let after = "FluidVoice works well"
        let insertedRange = NSRange(location: 0, length: (before as NSString).length)

        XCTAssertNil(AutomaticDictionaryCorrectionDetector.candidate(
            before: before,
            after: after,
            insertedRange: insertedRange
        ))
    }

    func testAutomaticDictionaryCorrectionAllowsContinuedCorrectionAtRangeEnd() {
        let change = AutomaticDictionaryTextChange(
            oldRange: NSRange(location: 5, length: 0),
            newRange: NSRange(location: 5, length: 1)
        )
        let insertedRange = NSRange(location: 0, length: 5)

        XCTAssertFalse(AutomaticDictionaryCorrectionDetector.isChangeInsideInsertedRange(
            change,
            insertedRange: insertedRange
        ))
        XCTAssertTrue(AutomaticDictionaryCorrectionDetector.isChangeInsideInsertedRange(
            change,
            insertedRange: insertedRange,
            allowsInsertionAtEnd: true
        ))
    }

    func testAutomaticDictionaryCorrectionKeepsWaitingWhileCaretTouchesCorrectedWord() {
        let correctedRange = NSRange(location: 8, length: 6)

        XCTAssertTrue(AutomaticDictionaryCorrectionDetector.selectionTouchesCandidate(
            NSRange(location: 14, length: 0),
            candidateRange: correctedRange
        ))
        XCTAssertFalse(AutomaticDictionaryCorrectionDetector.selectionTouchesCandidate(
            NSRange(location: 15, length: 0),
            candidateRange: correctedRange
        ))
    }

    func testAutomaticDictionaryCorrectionTreatsSpaceAfterWordAsCompletion() {
        let change = AutomaticDictionaryTextChange(
            oldRange: NSRange(location: 6, length: 0),
            newRange: NSRange(location: 6, length: 1)
        )
        let correctedRange = NSRange(location: 0, length: 6)

        XCTAssertFalse(AutomaticDictionaryCorrectionDetector.changeContinuesCandidate(
            change,
            after: "Barath ",
            candidateRange: correctedRange
        ))
        XCTAssertTrue(AutomaticDictionaryCorrectionDetector.changeContinuesCandidate(
            change,
            after: "Baratha",
            candidateRange: correctedRange
        ))
    }

    func testAutomaticDictionaryCorrectionIgnoresEditOutsideDictation() {
        let before = "Title: I met Barad"
        let after = "Heading: I met Barad"
        let insertedRange = (before as NSString).range(of: "I met Barad")

        XCTAssertNil(AutomaticDictionaryCorrectionDetector.candidate(
            before: before,
            after: after,
            insertedRange: insertedRange
        ))
    }

    func testAutomaticDictionaryCorrectionIgnoresCaseOnlyEdit() {
        let before = "fluidvoice"
        let after = "FluidVoice"
        let insertedRange = NSRange(location: 0, length: (before as NSString).length)

        XCTAssertNil(AutomaticDictionaryCorrectionDetector.candidate(
            before: before,
            after: after,
            insertedRange: insertedRange
        ))
    }

    func testAutomaticDictionaryCorrectionIgnoresPunctuationAndSpacingOnlyEdit() {
        let before = "Use Fluid-Voice today"
        let after = "Use Fluid Voice today"
        let insertedRange = NSRange(location: 0, length: (before as NSString).length)

        XCTAssertNil(AutomaticDictionaryCorrectionDetector.candidate(
            before: before,
            after: after,
            insertedRange: insertedRange
        ))
    }

    func testAutomaticDictionaryCorrectionIgnoresSingleCharacterCorrection() {
        let before = "Choose k today"
        let after = "Choose okay today"
        let insertedRange = NSRange(location: 0, length: (before as NSString).length)

        XCTAssertNil(AutomaticDictionaryCorrectionDetector.candidate(
            before: before,
            after: after,
            insertedRange: insertedRange
        ))
    }

    func testAutomaticDictionarySuggestionRequiresRepeatedCorrection() throws {
        let defaults = try self.makeSuggestionPolicyDefaults()
        var configuration = DictionarySuggestionPolicyConfig()
        configuration.globalCooldown = 0
        let policy = AutomaticDictionarySuggestionPolicy(defaults: defaults, configuration: configuration)
        let candidate = AutomaticDictionaryCorrectionCandidate(heardText: "Barad", correctedText: "Barath")
        let now = Date(timeIntervalSince1970: 1000)

        XCTAssertFalse(policy.shouldShow(candidate, now: now))
        XCTAssertTrue(policy.shouldShow(candidate, now: now.addingTimeInterval(60)))
    }

    func testAutomaticDictionarySuggestionPersistsDismissalCooldown() throws {
        let defaults = try self.makeSuggestionPolicyDefaults()
        var configuration = DictionarySuggestionPolicyConfig()
        configuration.requiredOccurrences = 1
        configuration.globalCooldown = 0
        configuration.dismissedPairCooldown = 100
        let candidate = AutomaticDictionaryCorrectionCandidate(heardText: "Barad", correctedText: "Barath")
        let now = Date(timeIntervalSince1970: 2000)

        let policy = AutomaticDictionarySuggestionPolicy(defaults: defaults, configuration: configuration)
        XCTAssertTrue(policy.shouldShow(candidate, now: now))
        policy.markShown(candidate, now: now)
        policy.record(.dismissed, for: candidate, now: now)

        let restoredPolicy = AutomaticDictionarySuggestionPolicy(defaults: defaults, configuration: configuration)
        XCTAssertFalse(restoredPolicy.shouldShow(candidate, now: now.addingTimeInterval(50)))
        XCTAssertTrue(restoredPolicy.shouldShow(candidate, now: now.addingTimeInterval(101)))
    }

    func testAutomaticDictionarySuggestionAppliesGlobalCooldown() throws {
        let defaults = try self.makeSuggestionPolicyDefaults()
        var configuration = DictionarySuggestionPolicyConfig()
        configuration.requiredOccurrences = 1
        configuration.globalCooldown = 600
        let policy = AutomaticDictionarySuggestionPolicy(defaults: defaults, configuration: configuration)
        let first = AutomaticDictionaryCorrectionCandidate(heardText: "Barad", correctedText: "Barath")
        let second = AutomaticDictionaryCorrectionCandidate(heardText: "Floral Voice", correctedText: "FluidVoice")
        let now = Date(timeIntervalSince1970: 3000)

        XCTAssertTrue(policy.shouldShow(first, now: now))
        policy.markShown(first, now: now)
        XCTAssertFalse(policy.shouldShow(second, now: now.addingTimeInterval(60)))
        XCTAssertTrue(policy.shouldShow(second, now: now.addingTimeInterval(601)))
    }

    func testAutomaticDictionarySuggestionStopsAfterSessionIgnoreLimit() throws {
        let defaults = try self.makeSuggestionPolicyDefaults()
        var configuration = DictionarySuggestionPolicyConfig()
        configuration.requiredOccurrences = 1
        configuration.globalCooldown = 0
        configuration.dismissedPairCooldown = 0
        let policy = AutomaticDictionarySuggestionPolicy(defaults: defaults, configuration: configuration)
        let now = Date(timeIntervalSince1970: 4000)

        for index in 0..<configuration.maximumSessionIgnores {
            let candidate = AutomaticDictionaryCorrectionCandidate(
                heardText: "heard \(index)",
                correctedText: "corrected \(index)"
            )
            XCTAssertTrue(policy.shouldShow(candidate, now: now.addingTimeInterval(Double(index))))
            policy.markShown(candidate, now: now.addingTimeInterval(Double(index)))
            policy.record(.timedOut, for: candidate, now: now.addingTimeInterval(Double(index)))
        }

        let next = AutomaticDictionaryCorrectionCandidate(heardText: "another error", correctedText: "another word")
        XCTAssertFalse(policy.shouldShow(next, now: now.addingTimeInterval(10)))
    }

    func testAutomaticDictionarySuggestionNeverReturnsAfterAcceptance() throws {
        let defaults = try self.makeSuggestionPolicyDefaults()
        var configuration = DictionarySuggestionPolicyConfig()
        configuration.requiredOccurrences = 1
        configuration.globalCooldown = 0
        let policy = AutomaticDictionarySuggestionPolicy(defaults: defaults, configuration: configuration)
        let candidate = AutomaticDictionaryCorrectionCandidate(heardText: "Barad", correctedText: "Barath")
        let now = Date(timeIntervalSince1970: 5000)

        XCTAssertTrue(policy.shouldShow(candidate, now: now))
        policy.record(.accepted, for: candidate, now: now)
        XCTAssertFalse(policy.shouldShow(candidate, now: now.addingTimeInterval(10_000)))
    }

    func testAutomaticDictionarySuggestionStopsAfterPairDismissalLimit() throws {
        let defaults = try self.makeSuggestionPolicyDefaults()
        var configuration = DictionarySuggestionPolicyConfig()
        configuration.requiredOccurrences = 1
        configuration.globalCooldown = 0
        configuration.dismissedPairCooldown = 0
        configuration.maximumSessionIgnores = 10
        let policy = AutomaticDictionarySuggestionPolicy(defaults: defaults, configuration: configuration)
        let candidate = AutomaticDictionaryCorrectionCandidate(heardText: "Barad", correctedText: "Barath")
        let now = Date(timeIntervalSince1970: 6000)

        for index in 0..<configuration.maximumPairDismissals {
            let date = now.addingTimeInterval(Double(index))
            XCTAssertTrue(policy.shouldShow(candidate, now: date))
            policy.record(.dismissed, for: candidate, now: date)
        }
        XCTAssertFalse(policy.shouldShow(candidate, now: now.addingTimeInterval(10)))
    }

    private func makeSuggestionPolicyDefaults() throws -> UserDefaults {
        let suiteName = "AutomaticDictionarySuggestionPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testDictionaryTransferImport_rejectsInvalidReplacementTriggerType() {
        let json = """
        {
          "replacements": [
            {
              "from": 42,
              "to": "FluidVoice"
            }
          ]
        }
        """

        XCTAssertThrowsError(try DictionaryTransferService.shared.decode(Data(json.utf8)))
    }

    func testDictionaryTransferImport_acceptsParakeetVocabularyTermsFile() throws {
        let json = """
        {
          "alpha": 2.8,
          "terms": [
            {
              "text": "FluidVoice",
              "aliases": ["fluid voice"],
              "weight": 13.0
            },
            {
              "text": "GEMBA-E"
            }
          ]
        }
        """

        let document = try DictionaryTransferService.shared.decode(Data(json.utf8))
        let state = try DictionaryTransferService.importState(
            document: document,
            mode: .replace,
            currentReplacements: [],
            currentCustomWords: []
        )

        XCTAssertEqual(state.replacements.count, 0)
        XCTAssertEqual(state.customWords.map(\.text), ["FluidVoice", "GEMBA-E"])
        XCTAssertEqual(state.customWords.map(\.weight), [13.0, 10.0])
        XCTAssertEqual(state.customWords.map(\.aliases), [[], []])
    }

    func testDictionaryTransferImport_acceptsLocalAPICustomWordsResponse() throws {
        let json = """
        {
          "count": 2,
          "items": [
            {
              "text": "FluidVoice",
              "weight": 10.0,
              "aliases": ["fluid voice"]
            },
            {
              "text": "Barath"
            }
          ]
        }
        """

        let document = try DictionaryTransferService.shared.decode(Data(json.utf8))
        let state = try DictionaryTransferService.importState(
            document: document,
            mode: .replace,
            currentReplacements: [],
            currentCustomWords: []
        )

        XCTAssertEqual(state.replacements.count, 0)
        XCTAssertEqual(state.customWords.map(\.text), ["FluidVoice", "Barath"])
        XCTAssertEqual(state.customWords.map(\.weight), [10.0, 10.0])
        XCTAssertEqual(state.customWords.map(\.aliases), [[], []])
    }

    func testDictationEndToEnd_whisperTiny_transcribesFixture() async throws {
        // Arrange
        let modelDirectory = Self.modelDirectoryForRun()
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let provider = WhisperProvider(modelDirectory: modelDirectory, modelOverride: .whisperTiny)

        // Act
        try await provider.prepare()
        let samples = try AudioFixtureLoader.load16kMonoFloatSamples(named: "dictation_fixture", ext: "wav")
        let result = try await provider.transcribe(samples)

        // Assert
        let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(raw.isEmpty, "Expected non-empty transcription text.")

        let normalized = Self.normalize(raw)
        XCTAssertTrue(normalized.contains("hello"), "Expected transcription to contain 'hello'. Got: \(raw)")
        XCTAssertTrue(normalized.contains("fluid"), "Expected transcription to contain 'fluid'. Got: \(raw)")
        XCTAssertTrue(
            normalized.contains("voice") || normalized.contains("fluidvoice") || normalized.contains("boys"),
            "Expected transcription to contain 'voice' (or a close variant like 'boys'). Got: \(raw)"
        )
    }

    func testWhisperProvider_legacyBinCacheDoesNotCountAsDownloadedOrDeletedByReadinessCheck() throws {
        let modelDirectory = Self.modelDirectoryForRun()
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let legacyURL = modelDirectory.appendingPathComponent("ggml-tiny.bin")
        try Data([0x01, 0x02, 0x03]).write(to: legacyURL)

        let provider = WhisperProvider(modelDirectory: modelDirectory, modelOverride: .whisperTiny)

        XCTAssertFalse(provider.modelsExistOnDisk())
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testWhisperProvider_readinessCheckDoesNotCreateMissingDirectory() {
        let modelDirectory = Self.modelDirectoryForRun()
        let provider = WhisperProvider(modelDirectory: modelDirectory, modelOverride: .whisperTiny)

        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDirectory.path))
        XCTAssertFalse(provider.modelsExistOnDisk())
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDirectory.path))
    }

    func testWhisperProvider_ggufCacheReadinessDoesNotDeleteLegacyUntilExplicitClear() async throws {
        let modelDirectory = Self.modelDirectoryForRun()
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let model = SettingsStore.SpeechModel.whisperTiny
        let ggufFilename = try XCTUnwrap(model.whisperModelFile)
        let legacyFilename = try XCTUnwrap(model.legacyWhisperModelFile)
        let ggufURL = modelDirectory.appendingPathComponent(ggufFilename)
        let legacyURL = modelDirectory.appendingPathComponent(legacyFilename)
        try Self.createSparseFile(at: ggufURL, size: model.expectedDownloadBytes)
        try Data([0x01, 0x02, 0x03]).write(to: legacyURL)

        let provider = WhisperProvider(modelDirectory: modelDirectory, modelOverride: model)

        XCTAssertTrue(provider.modelsExistOnDisk())
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        try await provider.clearCache()
        XCTAssertFalse(FileManager.default.fileExists(atPath: ggufURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testAppPromptBinding_profileOverridesModeSelection() {
        self.withPromptSettingsRestored {
            let settings = SettingsStore.shared

            let global = SettingsStore.DictationPromptProfile(
                name: "Global Dictate",
                prompt: "Global dictate prompt",
                mode: .dictate
            )
            let mail = SettingsStore.DictationPromptProfile(
                name: "Mail Dictate",
                prompt: "Mail dictate prompt",
                mode: .dictate
            )

            settings.dictationPromptProfiles = [global, mail]
            settings.selectedDictationPromptID = global.id
            settings.appPromptBindings = [
                SettingsStore.AppPromptBinding(
                    mode: .dictate,
                    appBundleID: "com.apple.mail",
                    appName: "Mail",
                    promptID: mail.id
                ),
            ]

            let mailResolution = settings.promptResolution(for: .dictate, appBundleID: "com.apple.mail")
            XCTAssertEqual(mailResolution.source, .appBindingProfile)
            XCTAssertEqual(mailResolution.profile?.id, mail.id)

            let notesResolution = settings.promptResolution(for: .dictate, appBundleID: "com.apple.notes")
            XCTAssertEqual(notesResolution.source, .selectedProfile)
            XCTAssertEqual(notesResolution.profile?.id, global.id)
        }
    }

    func testAppPromptBinding_defaultFallbackIgnoresGlobalSelection() {
        self.withPromptSettingsRestored {
            let settings = SettingsStore.shared

            let global = SettingsStore.DictationPromptProfile(
                name: "Global Dictate",
                prompt: "Global dictate prompt",
                mode: .dictate
            )

            settings.dictationPromptProfiles = [global]
            settings.selectedDictationPromptID = global.id
            settings.appPromptBindings = [
                SettingsStore.AppPromptBinding(
                    mode: .dictate,
                    appBundleID: "com.apple.mail",
                    appName: "Mail",
                    promptID: nil
                ),
            ]

            let mailResolution = settings.promptResolution(for: .dictate, appBundleID: "com.apple.mail")
            XCTAssertEqual(mailResolution.source, .appBindingDefault)
            XCTAssertNil(mailResolution.profile)
            XCTAssertEqual(
                mailResolution.systemPrompt,
                SettingsStore.defaultSystemPromptText(for: .dictate)
            )

            let otherResolution = settings.promptResolution(for: .dictate, appBundleID: "com.apple.notes")
            XCTAssertEqual(otherResolution.source, .selectedProfile)
            XCTAssertEqual(otherResolution.profile?.id, global.id)
        }
    }

    func testEditPromptOffUsesBuiltInDefaultAndPausesOverrides() {
        self.withPromptSettingsRestored {
            let settings = SettingsStore.shared

            let global = SettingsStore.DictationPromptProfile(
                name: "Global Edit",
                prompt: "Global edit prompt",
                mode: .edit
            )
            let mail = SettingsStore.DictationPromptProfile(
                name: "Mail Edit",
                prompt: "Mail edit prompt",
                mode: .edit
            )

            settings.dictationPromptProfiles = [global, mail]
            settings.selectedEditPromptID = global.id
            settings.defaultEditPromptOverride = "Custom default edit prompt"
            settings.appPromptBindings = [
                SettingsStore.AppPromptBinding(
                    mode: .edit,
                    appBundleID: "com.apple.mail",
                    appName: "Mail",
                    promptID: mail.id
                ),
            ]

            settings.setPromptOff(true, for: .edit)

            let paused = settings.promptResolution(for: .edit, appBundleID: "com.apple.mail")
            XCTAssertEqual(paused.source, .builtInDefault)
            XCTAssertNil(paused.profile)
            XCTAssertNil(paused.appBinding)
            XCTAssertEqual(paused.systemPrompt, SettingsStore.defaultSystemPromptText(for: .edit))

            settings.setSelectedPromptID(global.id, for: .edit)

            XCTAssertFalse(settings.isPromptOff(for: .edit))
            XCTAssertEqual(settings.promptResolution(for: .edit, appBundleID: nil).profile?.id, global.id)
        }
    }

    func testAppPromptBindings_reconcileInvalidPromptAndLegacyMode() {
        self.withPromptSettingsRestored {
            let settings = SettingsStore.shared

            let editProfile = SettingsStore.DictationPromptProfile(
                name: "Edit",
                prompt: "Edit prompt",
                mode: .edit
            )
            settings.dictationPromptProfiles = [editProfile]
            settings.appPromptBindings = [
                SettingsStore.AppPromptBinding(
                    mode: .rewrite,
                    appBundleID: " COM.APPLE.SAFARI ",
                    appName: "Safari",
                    promptID: "missing-profile"
                ),
            ]

            settings.reconcilePromptStateAfterProfileChanges()

            guard let binding = settings.appPromptBindings.first else {
                XCTFail("Expected normalized app prompt binding")
                return
            }

            XCTAssertEqual(binding.mode, .edit)
            XCTAssertEqual(binding.appBundleID, "com.apple.safari")
            XCTAssertNil(binding.promptID)
        }
    }

    func testLegacyBlockedPromptPlaceholderIsRemoved() {
        self.withPromptSettingsRestored {
            let settings = SettingsStore.shared

            let blocked = SettingsStore.DictationPromptProfile(
                name: "Blocked",
                prompt: "Blocked prompt",
                mode: .dictate
            )
            let real = SettingsStore.DictationPromptProfile(
                name: "Keep Me",
                prompt: "Real user prompt",
                mode: .dictate
            )

            settings.dictationPromptProfiles = [blocked, real]
            settings.selectedDictationPromptID = blocked.id
            settings.appPromptBindings = [
                SettingsStore.AppPromptBinding(
                    mode: .dictate,
                    appBundleID: "com.apple.notes",
                    appName: "Notes",
                    promptID: blocked.id
                ),
            ]

            settings.reconcilePromptStateAfterProfileChanges()

            XCTAssertEqual(settings.dictationPromptProfiles.map(\.id), [real.id])
            XCTAssertNil(settings.selectedDictationPromptID)
            XCTAssertEqual(settings.appPromptBindings.first?.promptID, nil)
        }
    }

    func testCustomProviderSettingsRoundTripThroughSettingsStore() {
        self.withProviderSettingsRestored {
            let settings = SettingsStore.shared
            let provider = SettingsStore.SavedProvider(
                id: "custom-provider-test",
                name: "Issue299 Temp",
                baseURL: "http://10.0.0.138:1234/v1",
                models: ["google/gemma-4-e4b"]
            )
            let providerKey = "custom:\(provider.id)"

            settings.savedProviders = [provider]
            settings.availableModelsByProvider = [providerKey: provider.models]
            settings.selectedModelByProvider = [providerKey: provider.models[0]]
            settings.selectedProviderID = provider.id

            XCTAssertEqual(settings.selectedProviderID, provider.id)
            XCTAssertEqual(settings.savedProviders, [provider])
            XCTAssertEqual(settings.availableModelsByProvider[providerKey], provider.models)
            XCTAssertEqual(settings.selectedModelByProvider[providerKey], provider.models[0])
        }
    }

    func testUnavailableSelectedProviderClearsSelection() {
        self.withProviderSettingsRestored {
            let settings = SettingsStore.shared

            settings.savedProviders = []
            settings.selectedProviderID = "removed-provider"

            XCTAssertEqual(settings.selectedProviderID, "")
        }
    }

    func testAppleIntelligenceIsNotAvailableAsABuiltInProvider() {
        XCTAssertFalse(ModelRepository.builtInProviderIDs.contains("apple-intelligence"))
        XCTAssertFalse(ModelRepository.shared.builtInProvidersList().contains { $0.id.contains("apple-intelligence") })
    }

    func testRetiredAppleIntelligenceStateIsPurgedWithoutSelectingAFallbackProvider() {
        self.withRestoredDefaults(
            keys: [
                self.selectedProviderIDKey,
                self.selectedAIModelKey,
                self.availableModelsByProviderKey,
                self.selectedModelByProviderKey,
                self.verifiedProviderFingerprintsKey,
                self.commandModeSelectedProviderIDKey,
                self.commandModeSelectedModelKey,
                self.rewriteModeSelectedProviderIDKey,
                self.rewriteModeSelectedModelKey,
                self.dictationPromptConfigurationsKey,
            ]
        ) {
            let settings = SettingsStore.shared
            let shortcut = HotkeyShortcut(keyCode: 1, modifierFlags: [.command])
            settings.selectedProviderID = "apple-intelligence"
            settings.selectedModel = "System Model"
            settings.availableModelsByProvider = ["apple-intelligence": ["System Model"]]
            settings.selectedModelByProvider = ["apple-intelligence": "System Model"]
            settings.verifiedProviderFingerprints = ["apple-intelligence": "apple-intelligence"]
            settings.commandModeSelectedProviderID = "apple-intelligence-disabled"
            settings.commandModeSelectedModel = "System Model"
            settings.rewriteModeSelectedProviderID = "apple-intelligence"
            settings.rewriteModeSelectedModel = "System Model"
            settings.dictationPromptConfigurations = [
                "__default__": SettingsStore.DictationPromptConfiguration(
                    shortcut: shortcut,
                    providerID: "apple-intelligence",
                    modelName: "System Model"
                ),
            ]

            settings.purgeRetiredAppleIntelligenceState()
            settings.purgeRetiredAppleIntelligenceState()

            XCTAssertEqual(settings.selectedProviderID, "")
            XCTAssertNil(settings.selectedModel)
            XCTAssertEqual(settings.commandModeSelectedProviderID, "")
            XCTAssertNil(settings.commandModeSelectedModel)
            XCTAssertEqual(settings.rewriteModeSelectedProviderID, "")
            XCTAssertNil(settings.rewriteModeSelectedModel)
            XCTAssertNil(settings.availableModelsByProvider["apple-intelligence"])
            XCTAssertNil(settings.selectedModelByProvider["apple-intelligence"])
            XCTAssertNil(settings.verifiedProviderFingerprints["apple-intelligence"])
            XCTAssertEqual(settings.dictationPromptConfigurations["__default__"]?.shortcut, shortcut)
            XCTAssertEqual(settings.dictationPromptConfigurations["__default__"]?.providerID, "")
            XCTAssertEqual(settings.dictationPromptConfigurations["__default__"]?.modelName, "")
            XCTAssertFalse(DictationAIPostProcessingGate.isProviderConfigured())
        }
    }

    func testDictationProviderRouteUsesPromptConfigurationWithoutMutatingGlobalSelection() {
        self.withRestoredDefaults(
            keys: [
                self.selectedProviderIDKey,
                self.selectedModelByProviderKey,
                self.verifiedProviderFingerprintsKey,
                self.dictationPromptConfigurationsKey,
                self.dictationPromptOffKey,
                self.selectedDictationPromptIDKey,
            ]
        ) {
            let settings = SettingsStore.shared
            settings.selectedProviderID = "openai"
            settings.selectedModelByProvider = ["openai": "gpt-4.1", "ollama": "test-local-model"]
            settings.verifiedProviderFingerprints = [
                "ollama": DictationAIPostProcessingGate.providerFingerprint(
                    baseURL: ModelRepository.shared.defaultBaseURL(for: "ollama"),
                    apiKey: ""
                ) ?? "",
            ]
            settings.setDictationPromptSelection(.default, for: .primary)
            settings.setDictationPromptConfiguration(
                SettingsStore.DictationPromptConfiguration(
                    providerID: "ollama",
                    modelName: "test-local-model"
                ),
                for: .default
            )

            let route = DictationProviderRoute.resolve(settings: settings, dictationSlot: .primary)

            XCTAssertEqual(route.providerID, "ollama")
            XCTAssertEqual(route.providerKey, "ollama")
            XCTAssertEqual(route.model, "test-local-model")
            XCTAssertEqual(settings.selectedProviderID, "openai")
            XCTAssertEqual(settings.selectedModelByProvider["openai"], "gpt-4.1")

            XCTAssertTrue(DictationAIPostProcessingGate.isConfigured(for: .primary))
            XCTAssertEqual(settings.selectedProviderID, "openai")
        }
    }

    func testDictationProviderRouteReturnsEmptyRouteForUnverifiedPrivateAI() {
        self.withPromptAndProviderSettingsRestored {
            let settings = SettingsStore.shared
            settings.verifiedProviderFingerprints = [:]

            let route = DictationProviderRoute.privateAIRoute(settings: settings)

            XCTAssertEqual(
                route,
                DictationProviderRoute(providerID: "", providerKey: "", baseURL: "", model: "", apiKey: "")
            )
            XCTAssertFalse(route.usesPrivateAI)
        }
    }

    func testDictationProviderRouteUsesAppBoundPromptConfiguration() {
        self.withRestoredDefaults(
            keys: [
                self.dictationPromptProfilesKey,
                self.appPromptBindingsKey,
                self.dictationPromptRoutingScopeKey,
                self.selectedProviderIDKey,
                self.selectedModelByProviderKey,
                self.verifiedProviderFingerprintsKey,
                self.dictationPromptConfigurationsKey,
                self.dictationPromptOffKey,
                self.selectedDictationPromptIDKey,
            ]
        ) {
            let settings = SettingsStore.shared
            let appBundleID = "com.example.editor"
            let profile = SettingsStore.DictationPromptProfile(
                name: "Editor",
                prompt: "Clean up text for this editor.",
                mode: .dictate
            )
            settings.dictationPromptProfiles = [profile]
            settings.appPromptBindings = [
                SettingsStore.AppPromptBinding(
                    mode: .dictate,
                    appBundleID: appBundleID,
                    appName: "Editor",
                    promptID: profile.id
                ),
            ]
            settings.dictationPromptRoutingScope = .allApps
            settings.selectedProviderID = "openai"
            settings.selectedModelByProvider = ["openai": "gpt-4.1", "ollama": "editor-model"]
            settings.verifiedProviderFingerprints = [
                "ollama": DictationAIPostProcessingGate.providerFingerprint(
                    baseURL: ModelRepository.shared.defaultBaseURL(for: "ollama"),
                    apiKey: ""
                ) ?? "",
            ]
            settings.setDictationPromptSelection(.default, for: .primary)
            settings.setDictationPromptConfiguration(
                SettingsStore.DictationPromptConfiguration(
                    providerID: "openai",
                    modelName: "gpt-4.1"
                ),
                for: .default
            )
            settings.setDictationPromptConfiguration(
                SettingsStore.DictationPromptConfiguration(
                    providerID: "ollama",
                    modelName: "editor-model"
                ),
                for: .profile(profile.id)
            )

            let route = DictationProviderRoute.resolve(
                settings: settings,
                dictationSlot: .primary,
                appBundleID: appBundleID
            )

            XCTAssertEqual(route.providerID, "ollama")
            XCTAssertEqual(route.model, "editor-model")
            XCTAssertEqual(settings.selectedProviderID, "openai")
            XCTAssertTrue(DictationAIPostProcessingGate.isConfigured(for: .primary, appBundleID: appBundleID))
        }
    }

    func testPostProcessingRouteUsesGlobalProviderWithoutAppContext() {
        self.withRestoredDefaults(
            keys: [
                self.dictationPromptRoutingScopeKey,
                self.selectedProviderIDKey,
                self.selectedModelByProviderKey,
                self.dictationPromptOffKey,
                self.selectedDictationPromptIDKey,
            ]
        ) {
            let settings = SettingsStore.shared
            settings.dictationPromptRoutingScope = .selectedAppsOnly
            settings.selectedProviderID = "openai"
            settings.selectedModelByProvider = ["openai": "gpt-4.1"]
            settings.setDictationPromptSelection(.default, for: .primary)

            let route = DictationProviderRoute.resolveForPostProcessing(
                settings: settings,
                dictationSlot: .primary
            )

            XCTAssertEqual(route.providerID, "openai")
            XCTAssertEqual(route.model, "gpt-4.1")
        }
    }

    func testPrivateAIProviderDictationPromptSelection_allowsOffAndRestoresNonFluidPrompt() {
        self.withPromptAndProviderSettingsRestored {
            let settings = SettingsStore.shared
            let custom = SettingsStore.DictationPromptProfile(
                name: "Custom Dictate",
                prompt: "Use the custom prompt",
                mode: .dictate
            )
            settings.dictationPromptProfiles = [custom]
            settings.selectedModelByProvider = [
                "openai": "gpt-4.1",
                PrivateAIProviderFeature.shared.providerID: PrivateAIProviderFeature.shared.providerID,
            ]
            settings.selectedProviderID = "openai"
            settings.setDictationPromptSelection(.profile(custom.id))

            XCTAssertEqual(settings.dictationPromptSelection(for: .primary), .profile(custom.id))

            settings.selectedProviderID = PrivateAIProviderFeature.shared.providerID
            if PrivateFeatures.privateAIProvider {
                XCTAssertEqual(settings.dictationPromptSelection(for: .primary), .privateAI)
            } else {
                XCTAssertEqual(settings.dictationPromptSelection(for: .primary), .profile(custom.id))
            }

            settings.setDictationPromptSelection(.off)
            XCTAssertEqual(settings.dictationPromptSelection(for: .primary), .off)

            settings.selectedProviderID = "openai"
            XCTAssertEqual(settings.dictationPromptSelection(for: .primary), .off)

            settings.setDictationPromptSelection(.profile(custom.id))
            XCTAssertEqual(settings.dictationPromptSelection(for: .primary), .profile(custom.id))
        }
    }

    func testPrivateAIProviderDictationPromptSelection_usesOnlyFluidPromptOrOffWhileSelected() {
        self.withPromptAndProviderSettingsRestored {
            let settings = SettingsStore.shared
            let custom = SettingsStore.DictationPromptProfile(
                name: "Custom Dictate",
                prompt: "Use the custom prompt",
                mode: .dictate
            )
            settings.dictationPromptProfiles = [custom]
            settings.selectedModelByProvider = [
                "openai": "gpt-4.1",
                PrivateAIProviderFeature.shared.providerID: PrivateAIProviderFeature.shared.providerID,
            ]

            settings.selectedProviderID = PrivateAIProviderFeature.shared.providerID
            settings.setDictationPromptSelection(.default)
            XCTAssertEqual(
                settings.dictationPromptSelection(for: .primary),
                PrivateFeatures.privateAIProvider ? .privateAI : .default
            )

            settings.setDictationPromptSelection(.profile(custom.id))
            XCTAssertEqual(
                settings.dictationPromptSelection(for: .primary),
                PrivateFeatures.privateAIProvider ? .privateAI : .profile(custom.id)
            )

            settings.setDictationPromptSelection(.off)
            XCTAssertEqual(settings.dictationPromptSelection(for: .primary), .off)
            XCTAssertEqual(settings.dictationPromptDisplayName(for: .primary, appBundleID: nil), "Off")

            settings.selectedProviderID = "openai"
            settings.setDictationPromptSelection(.profile(custom.id))
            XCTAssertEqual(settings.dictationPromptSelection(for: .primary), .profile(custom.id))
        }
    }

    func testPrivateAIProviderPrefixKVCache_defaultsOnAndPersistsToggle() {
        self.withRestoredDefaults(keys: [self.privateAIPrefixKVCacheEnabledKey]) {
            let settings = SettingsStore.shared

            XCTAssertTrue(settings.privateAIPrefixKVCacheEnabled)

            settings.privateAIPrefixKVCacheEnabled = false
            XCTAssertFalse(settings.privateAIPrefixKVCacheEnabled)

            settings.privateAIPrefixKVCacheEnabled = true
            XCTAssertTrue(settings.privateAIPrefixKVCacheEnabled)
        }
    }

    func testPrivateAIProviderBoost_defaultsOnAndPersistsToggle() {
        self.withRestoredDefaults(keys: [self.privateAIBoostEnabledKey]) {
            let settings = SettingsStore.shared

            XCTAssertTrue(settings.privateAIBoostEnabled)

            settings.privateAIBoostEnabled = false
            XCTAssertFalse(settings.privateAIBoostEnabled)

            settings.privateAIBoostEnabled = true
            XCTAssertTrue(settings.privateAIBoostEnabled)
        }
    }

    func testPrivateAIProviderContextTokenLimit_defaultsPersistsAndClamps() {
        self.withRestoredDefaults(keys: [self.privateAIContextTokenLimitKey, self.privateAIContextDefaultMigratedTo4KKey]) {
            let settings = SettingsStore.shared
            UserDefaults.standard.removeObject(forKey: self.privateAIContextTokenLimitKey)
            UserDefaults.standard.removeObject(forKey: self.privateAIContextDefaultMigratedTo4KKey)

            XCTAssertEqual(settings.privateAIContextTokenLimit, 4096)

            settings.privateAIContextTokenLimit = 4096
            XCTAssertEqual(settings.privateAIContextTokenLimit, 4096)

            settings.privateAIContextTokenLimit = 1024
            XCTAssertEqual(settings.privateAIContextTokenLimit, 2048)

            settings.privateAIContextTokenLimit = 16_384
            XCTAssertEqual(settings.privateAIContextTokenLimit, 8192)
        }
    }

    func testPrivateAIProviderLocalRuntimeOnlyHandlesPrivateModels() {
        self.withRestoredDefaults(keys: [self.privateAILocalModelPathKey]) {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("FluidVoice-PrivateAI-\(UUID().uuidString).gguf")
            XCTAssertTrue(FileManager.default.createFile(atPath: tempURL.path, contents: Data(), attributes: nil))
            defer { try? FileManager.default.removeItem(at: tempURL) }

            UserDefaults.standard.set(tempURL.path, forKey: self.privateAILocalModelPathKey)

            XCTAssertEqual(
                PrivateAIIntegrationService.isLocalRuntimeConfigured,
                PrivateFeatures.privateAIProvider
            )
            XCTAssertFalse(PrivateAIIntegrationService.shouldHandleDictation(model: "gpt-4.1"))
            XCTAssertEqual(
                PrivateAIIntegrationService.shouldHandleDictation(model: PrivateAIProviderFeature.shared.providerID),
                PrivateFeatures.privateAIProvider
            )
        }
    }

    func testPrivateAIProviderLocalRuntimeDoesNotConfigureNonFluidProvider() {
        self.withRestoredDefaults(
            keys: [
                self.privateAILocalModelPathKey,
                self.selectedProviderIDKey,
                self.selectedModelByProviderKey,
                self.verifiedProviderFingerprintsKey,
                self.selectedDictationPromptIDKey,
                self.dictationPromptOffKey,
            ]
        ) {
            let settings = SettingsStore.shared
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("FluidVoice-PrivateAI-\(UUID().uuidString).gguf")
            XCTAssertTrue(FileManager.default.createFile(atPath: tempURL.path, contents: Data(), attributes: nil))
            defer { try? FileManager.default.removeItem(at: tempURL) }

            UserDefaults.standard.set(tempURL.path, forKey: self.privateAILocalModelPathKey)
            settings.selectedProviderID = "openai"
            settings.selectedModelByProvider = ["openai": "gpt-4.1"]
            settings.verifiedProviderFingerprints = [:]
            settings.setDictationPromptSelection(.default)

            XCTAssertEqual(
                PrivateAIIntegrationService.isLocalRuntimeConfigured,
                PrivateFeatures.privateAIProvider
            )
            XCTAssertFalse(DictationAIPostProcessingGate.isConfigured(for: .primary, appBundleID: nil))
        }
    }

    func testMLXUpgradeOfferOnlyTargetsLegacyAppleSiliconInstalls() {
        let eligible = PrivateAIMLXUpgradeCoordinator.shouldOffer(
            hasPrivateProvider: true,
            isAppleSilicon: true,
            appVersion: "1.6.3",
            backendPreferenceWasSet: false,
            hasLegacyLlamaModel: true,
            hasMLXModel: false,
            offerWasHandled: false
        )
        XCTAssertTrue(eligible)

        XCTAssertFalse(PrivateAIMLXUpgradeCoordinator.shouldOffer(
            hasPrivateProvider: true,
            isAppleSilicon: false,
            appVersion: "1.6.3",
            backendPreferenceWasSet: false,
            hasLegacyLlamaModel: true,
            hasMLXModel: false,
            offerWasHandled: false
        ))
        XCTAssertFalse(PrivateAIMLXUpgradeCoordinator.shouldOffer(
            hasPrivateProvider: true,
            isAppleSilicon: true,
            appVersion: "1.6.3",
            backendPreferenceWasSet: true,
            hasLegacyLlamaModel: true,
            hasMLXModel: false,
            offerWasHandled: false
        ))
        XCTAssertFalse(PrivateAIMLXUpgradeCoordinator.shouldOffer(
            hasPrivateProvider: true,
            isAppleSilicon: true,
            appVersion: "1.6.3",
            backendPreferenceWasSet: false,
            hasLegacyLlamaModel: false,
            hasMLXModel: false,
            offerWasHandled: false
        ))
        XCTAssertFalse(PrivateAIMLXUpgradeCoordinator.shouldOffer(
            hasPrivateProvider: true,
            isAppleSilicon: true,
            appVersion: "1.6.3",
            backendPreferenceWasSet: false,
            hasLegacyLlamaModel: true,
            hasMLXModel: true,
            offerWasHandled: false
        ))
        XCTAssertFalse(PrivateAIMLXUpgradeCoordinator.shouldOffer(
            hasPrivateProvider: true,
            isAppleSilicon: true,
            appVersion: "1.6.3",
            backendPreferenceWasSet: false,
            hasLegacyLlamaModel: true,
            hasMLXModel: false,
            offerWasHandled: true
        ))
        for version in ["1.6.2", "1.6.4", "2.0.0", ""] {
            XCTAssertFalse(PrivateAIMLXUpgradeCoordinator.shouldOffer(
                hasPrivateProvider: true,
                isAppleSilicon: true,
                appVersion: version,
                backendPreferenceWasSet: false,
                hasLegacyLlamaModel: true,
                hasMLXModel: false,
                offerWasHandled: false
            ))
        }
    }

    func testMLXUpgradePreparedOfferIsRevalidatedBeforeResuming() {
        XCTAssertTrue(PrivateAIMLXUpgradeCoordinator.shouldResumePreparedOffer(
            hasPrivateProvider: true,
            isAppleSilicon: true,
            appVersion: "1.6.3",
            backendPreference: .llama,
            hasLegacyLlamaModel: true,
            hasMLXModel: false
        ))

        for state in [
            (true, true, "1.6.3", SettingsStore.PrivateAIBackendPreference.mlx, true, false),
            (true, true, "1.6.3", SettingsStore.PrivateAIBackendPreference.llama, false, false),
            (true, true, "1.6.3", SettingsStore.PrivateAIBackendPreference.llama, true, true),
            (true, true, "1.6.4", SettingsStore.PrivateAIBackendPreference.llama, true, false),
            (true, false, "1.6.3", SettingsStore.PrivateAIBackendPreference.llama, true, false),
            (false, true, "1.6.3", SettingsStore.PrivateAIBackendPreference.llama, true, false),
            (true, true, "1.6.3", nil, true, false),
        ] {
            XCTAssertFalse(PrivateAIMLXUpgradeCoordinator.shouldResumePreparedOffer(
                hasPrivateProvider: state.0,
                isAppleSilicon: state.1,
                appVersion: state.2,
                backendPreference: state.3,
                hasLegacyLlamaModel: state.4,
                hasMLXModel: state.5
            ))
        }
    }

    func testPrivateAIProviderDoesNotConfigureCommandMode() {
        guard PrivateFeatures.privateAIProvider else { return }

        self.withRestoredDefaults(
            keys: [
                self.selectedProviderIDKey,
                self.commandModeLinkedToGlobalKey,
                self.commandModeSelectedProviderIDKey,
                self.commandModeSelectedModelKey,
            ]
        ) {
            let settings = SettingsStore.shared
            settings.selectedProviderID = PrivateAIProviderFeature.shared.providerID
            settings.commandModeLinkedToGlobal = true
            settings.commandModeSelectedProviderID = PrivateAIProviderFeature.shared.providerID
            settings.commandModeSelectedModel = PrivateAIProviderFeature.shared.providerID

            XCTAssertEqual(settings.effectiveCommandModeProviderID, "")
            XCTAssertTrue(settings.commandModeReadinessIssue?.contains("coming soon") == true)
            XCTAssertFalse(settings.isCommandModeProviderVerified(PrivateAIProviderFeature.shared.providerID))
        }
    }

    func testRollbackBackupsPreferFilenameTimestampOverModificationDate() {
        let firstBackupWithNewestModificationDate = URL(
            fileURLWithPath: "/tmp/FluidVoice-1.5.11-beta.1-100.app"
        )
        let secondBackup = URL(
            fileURLWithPath: "/tmp/FluidVoice-1.5.11-beta.2-150.app"
        )
        let thirdBackup = URL(
            fileURLWithPath: "/tmp/FluidVoice-1.5.11-beta.3-rollback-200.app"
        )
        let fourthBackupWithOldestModificationDate = URL(
            fileURLWithPath: "/tmp/FluidVoice-1.5.11-beta.4-rollback-300.app"
        )
        let modificationDates = [
            firstBackupWithNewestModificationDate: Date(timeIntervalSince1970: 500),
            secondBackup: Date(timeIntervalSince1970: 300),
            thirdBackup: Date(timeIntervalSince1970: 50),
            fourthBackupWithOldestModificationDate: Date(timeIntervalSince1970: 10),
        ]

        let sorted = SimpleUpdater.sortedRollbackBackups(
            [
                firstBackupWithNewestModificationDate,
                secondBackup,
                thirdBackup,
                fourthBackupWithOldestModificationDate,
            ]
        ) { url in
            modificationDates[url]
        }

        XCTAssertEqual(
            sorted,
            [
                fourthBackupWithOldestModificationDate,
                thirdBackup,
                secondBackup,
                firstBackupWithNewestModificationDate,
            ]
        )
    }

    func testRollbackVersionIgnoresCurrentAppVersion() {
        XCTAssertFalse(SimpleUpdater.isRollbackVersion("1.5.11-beta.3", differentFrom: "1.5.11-beta.3"))
        XCTAssertTrue(SimpleUpdater.isRollbackVersion("1.5.11-beta.2", differentFrom: "1.5.11-beta.3"))
        XCTAssertFalse(SimpleUpdater.isRollbackVersion(nil, differentFrom: "1.5.11-beta.3"))
    }

    // MARK: - Model download HTML/markup rejection (#353)

    func testLooksLikeHTML_rejectsMarkupVariants() {
        // A proxy/block page or stand-in markup document must be rejected regardless of
        // which markup token it opens with — not just <!doctype / <html.
        let rejected = [
            "<!DOCTYPE html><html lang=\"en\"><head></head></html>",
            "<html><body>Blocked by corporate proxy</body></html>",
            "<script>window.location='https://proxy'</script>",
            "<head><title>Access Denied</title></head>",
            "<body>Forbidden</body>",
            "<meta http-equiv=\"refresh\" content=\"0\">",
            "<!-- corporate gateway notice -->",
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><error>blocked</error>",
            "</html>",
            "<!doctype HTML PUBLIC \"-//W3C//DTD HTML 4.01//EN\">",
        ]
        for markup in rejected {
            XCTAssertTrue(
                HuggingFaceModelDownloader.looksLikeHTML(Data(markup.utf8)),
                "Expected markup to be rejected: \(markup)"
            )
        }
    }

    func testLooksLikeHTML_rejectsLeadingWhitespaceAndBOMVariants() {
        let bom: [UInt8] = [0xef, 0xbb, 0xbf]

        // Leading ASCII whitespace before the markup token.
        XCTAssertTrue(HuggingFaceModelDownloader.looksLikeHTML(Data("   \n\t<!DOCTYPE html>".utf8)))
        XCTAssertTrue(HuggingFaceModelDownloader.looksLikeHTML(Data("\r\n  <html>".utf8)))

        // UTF-8 BOM, then markup.
        XCTAssertTrue(HuggingFaceModelDownloader.looksLikeHTML(Data(bom + Array("<html>".utf8))))

        // BOM, then whitespace, then an XML declaration.
        XCTAssertTrue(
            HuggingFaceModelDownloader.looksLikeHTML(Data(bom + Array("  \n<?xml version=\"1.0\"?>".utf8)))
        )
    }

    func testLooksLikeHTML_acceptsModelArtifacts() {
        // JSON object (vocab / metadata / Manifest) — note the embedded `<pad>` must NOT
        // trip the detector; only a LEADING `<` does.
        XCTAssertFalse(HuggingFaceModelDownloader.looksLikeHTML(Data("{\"0\": \"<pad>\", \"1\": \"a\"}".utf8)))
        // JSON array body.
        XCTAssertFalse(HuggingFaceModelDownloader.looksLikeHTML(Data("[1, 2, 3]".utf8)))
        // MIL program text (`model.mil`).
        XCTAssertFalse(HuggingFaceModelDownloader.looksLikeHTML(Data("program(1.0)\n[buildInfo = ...]".utf8)))
        // Binary CoreML / Mach-O magic prefix.
        XCTAssertFalse(HuggingFaceModelDownloader.looksLikeHTML(Data([0xcf, 0xfa, 0xed, 0xfe, 0x07, 0x00])))
        // Leading-NUL binary (e.g. coremldata.bin / weight.bin style payloads).
        XCTAssertFalse(HuggingFaceModelDownloader.looksLikeHTML(Data([0x00, 0x00, 0x01, 0x3c, 0x68])))
        // Empty payload.
        XCTAssertFalse(HuggingFaceModelDownloader.looksLikeHTML(Data()))
        // A stray `<` NOT followed by a markup-ish byte must not be over-rejected.
        XCTAssertFalse(HuggingFaceModelDownloader.looksLikeHTML(Data("< not markup".utf8)))
        XCTAssertFalse(HuggingFaceModelDownloader.looksLikeHTML(Data("<".utf8)))
    }

    func testValidateDownloadedFile_rejectsHTMLBodyAndAcceptsJSON() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluidVoice-ValidateTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // HTML body written without an HTML Content-Type (response: nil) must still be
        // rejected by the byte-sniff path.
        let htmlURL = dir.appendingPathComponent("coremldata.bin")
        try Data("<!DOCTYPE html><html><body>Blocked</body></html>".utf8).write(to: htmlURL)
        XCTAssertThrowsError(
            try HuggingFaceModelDownloader.validateDownloadedFile(
                at: htmlURL,
                response: nil,
                relativePath: "coremldata.bin"
            )
        )

        // A real JSON vocab payload must pass validation.
        let jsonURL = dir.appendingPathComponent("parakeet_v3_vocab.json")
        try Data("{\"0\": \"<pad>\", \"1\": \"the\"}".utf8).write(to: jsonURL)
        XCTAssertNoThrow(
            try HuggingFaceModelDownloader.validateDownloadedFile(
                at: jsonURL,
                response: nil,
                relativePath: "parakeet_v3_vocab.json"
            )
        )
    }

    func testCachedFileIsMarkup_detectsCachedCorruptHTMLAndAcceptsModelData() throws {
        // Guards the #353 cached-file path: a corrupt HTML payload already on disk (cached
        // before download-time validation existed) must be detected so it is re-downloaded,
        // while a real model artifact must not be flagged, and an unreadable path must be
        // treated as valid (never deleted on uncertainty).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluidVoice-CachedMarkupTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A cached HTML/proxy page persisted as a model file must be detected as markup.
        let htmlURL = dir.appendingPathComponent("coremldata.bin")
        try Data("<!DOCTYPE html><html><body>Blocked by proxy</body></html>".utf8).write(to: htmlURL)
        XCTAssertTrue(HuggingFaceModelDownloader.cachedFileIsMarkup(at: htmlURL))

        // A real JSON vocab payload must not be flagged.
        let jsonURL = dir.appendingPathComponent("parakeet_v3_vocab.json")
        try Data("{\"0\": \"<pad>\", \"1\": \"the\"}".utf8).write(to: jsonURL)
        XCTAssertFalse(HuggingFaceModelDownloader.cachedFileIsMarkup(at: jsonURL))

        // An unreadable / missing path must be treated as valid (conservative on read error).
        let missingURL = dir.appendingPathComponent("does-not-exist.bin")
        XCTAssertFalse(HuggingFaceModelDownloader.cachedFileIsMarkup(at: missingURL))
    }

    func testCachedPayloadContainsMarkup_detectsCorruptFileInPresentArtifactTree() throws {
        // Guards the #353 provider-PREFLIGHT path: a corrupt HTML payload nested inside a
        // present `.mlpackage` bundle (or a loose required file) must be detected so the preflight
        // re-downloads instead of trusting a file-existence/manifest check, while a valid cached
        // tree must not be flagged, and missing/empty required entries stay conservative.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluidVoice-CachedPayloadTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A realistic `.mlpackage` layout: a JSON manifest plus a nested binary weight payload.
        let packageName = "encoder.mlpackage"
        let weightsDir = root.appendingPathComponent(packageName)
            .appendingPathComponent("Data/com.apple.CoreML/weights", isDirectory: true)
        try FileManager.default.createDirectory(at: weightsDir, withIntermediateDirectories: true)
        let manifestURL = root.appendingPathComponent(packageName).appendingPathComponent("Manifest.json")
        try Data("{\"fileFormatVersion\": \"1.0.0\"}".utf8).write(to: manifestURL)
        let weightURL = weightsDir.appendingPathComponent("weight.bin")
        try Data([0x00, 0x01, 0x02, 0x03, 0x04]).write(to: weightURL)

        // A loose required file (e.g. a tokenizer) with real binary content.
        let tokenizerURL = root.appendingPathComponent("tokenizer.model")
        try Data([0x0a, 0x09, 0x05, 0x00]).write(to: tokenizerURL)

        let entries = [packageName, "tokenizer.model"]

        // An all-valid tree must not be flagged.
        XCTAssertFalse(
            HuggingFaceModelDownloader.cachedPayloadContainsMarkup(root: root, relativePaths: entries)
        )

        // A proxy HTML page persisted as a binary INSIDE the package must be detected.
        try Data("<!DOCTYPE html><html><body>Blocked by proxy</body></html>".utf8).write(to: weightURL)
        XCTAssertTrue(
            HuggingFaceModelDownloader.cachedPayloadContainsMarkup(root: root, relativePaths: entries)
        )

        // Restore the binary; corrupt the loose required file instead — must still be detected.
        try Data([0x00, 0x01, 0x02, 0x03, 0x04]).write(to: weightURL)
        try Data("<html><head></head></html>".utf8).write(to: tokenizerURL)
        XCTAssertTrue(
            HuggingFaceModelDownloader.cachedPayloadContainsMarkup(root: root, relativePaths: entries)
        )

        // Missing entries and an empty required directory are conservative: never flagged corrupt
        // on uncertainty (incompleteness is the existence check's concern, not this one's).
        try Data([0x0a, 0x09, 0x05, 0x00]).write(to: tokenizerURL)
        let emptyPackage = root.appendingPathComponent("empty.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyPackage, withIntermediateDirectories: true)
        XCTAssertFalse(
            HuggingFaceModelDownloader.cachedPayloadContainsMarkup(
                root: root,
                relativePaths: ["empty.mlpackage", "does-not-exist.json"]
            )
        )
    }

    private static func modelDirectoryForRun() -> URL {
        // Use a stable path on CI so GitHub Actions cache can speed up runs.
        if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" ||
            ProcessInfo.processInfo.environment["CI"] == "true"
        {
            guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                preconditionFailure("Could not find caches directory")
            }
            return caches.appendingPathComponent("WhisperModels")
        }

        // Local runs: isolate per test execution.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluidVoiceTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return base.appendingPathComponent("WhisperModels", isDirectory: true)
    }

    private static func createSparseFile(at url: URL, size: Int64) throws {
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
    }

    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let noPunct = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.punctuationCharacters.contains(scalar) {
                return " "
            }
            return Character(scalar)
        }
        return String(noPunct)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func withRestoredDefaults(keys: [String], run: () -> Void) {
        let defaults = UserDefaults.standard
        var snapshot: [String: Any] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) {
                snapshot[key] = value
            }
        }

        defer {
            for key in keys {
                if let previous = snapshot[key] {
                    defaults.set(previous, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        run()
    }

    private func withPromptSettingsRestored(run: () -> Void) {
        self.withRestoredDefaults(
            keys: [
                self.dictationPromptProfilesKey,
                self.appPromptBindingsKey,
                self.selectedDictationPromptIDKey,
                self.selectedEditPromptIDKey,
                self.dictationPromptOffKey,
                self.editPromptOffKey,
                self.defaultDictationPromptOverrideKey,
                self.defaultEditPromptOverrideKey,
            ],
            run: run
        )
    }

    private func withProviderSettingsRestored(run: () -> Void) {
        self.withRestoredDefaults(
            keys: [
                self.savedProvidersKey,
                self.selectedProviderIDKey,
                self.availableModelsByProviderKey,
                self.selectedModelByProviderKey,
            ],
            run: run
        )
    }

    private func withPromptAndProviderSettingsRestored(run: () -> Void) {
        self.withRestoredDefaults(
            keys: [
                self.dictationPromptProfilesKey,
                self.appPromptBindingsKey,
                self.selectedDictationPromptIDKey,
                self.selectedEditPromptIDKey,
                self.dictationPromptOffKey,
                self.editPromptOffKey,
                self.defaultDictationPromptOverrideKey,
                self.defaultEditPromptOverrideKey,
                self.savedProvidersKey,
                self.selectedProviderIDKey,
                self.availableModelsByProviderKey,
                self.selectedModelByProviderKey,
                self.verifiedProviderFingerprintsKey,
                self.privateAISelectedModelIDKey,
            ],
            run: run
        )
    }
}

@MainActor
extension DictationE2ETests {
    func testLegacyHistoryDecodesNilSpeechProviderAndModel() throws {
        let entry = TranscriptionHistoryEntry(
            rawText: "legacy raw",
            processedText: "legacy processed",
            appName: "Editor",
            windowTitle: "Document",
            wasAIProcessed: false
        )
        let encoded = try JSONEncoder().encode(entry)
        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyObject.removeValue(forKey: "speechProvider")
        legacyObject.removeValue(forKey: "speechModel")

        let decoded = try JSONDecoder().decode(
            TranscriptionHistoryEntry.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )

        XCTAssertNil(decoded.speechProvider)
        XCTAssertNil(decoded.speechModel)
    }

    func testSonioxHistoryRoundTripsProviderAndBackendModelID() throws {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let historyStore = TranscriptionHistoryStore.shared
        let originalHistory = historyStore.makeBackupPayload()
        defer {
            settings.selectedSpeechModel = originalModel
            historyStore.restore(from: originalHistory)
        }
        historyStore.restore(from: [])
        let configuration = try XCTUnwrap(RecordingSpeechConfiguration(
            inputSourceID: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",
            localeIdentifier: "ja-JP",
            model: .sonioxV5,
            languageBinding: .soniox(.init(languageCode: "ja", isStrict: true, region: .japan))
        ))
        settings.selectedSpeechModel = .appleSpeech

        historyStore.addEntry(
            rawText: "captured output",
            processedText: "delivered output",
            appName: "Editor",
            windowTitle: "Document",
            wasAIProcessed: false,
            speechProvider: configuration.model.provider.rawValue.lowercased(),
            speechModel: configuration.model.backendModelIdentifier
        )
        let entry = try XCTUnwrap(historyStore.makeBackupPayload().first)
        let encoded = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(TranscriptionHistoryEntry.self, from: encoded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(decoded.speechProvider, "soniox")
        XCTAssertEqual(decoded.speechModel, "stt-rt-v5")
        XCTAssertNil(object["apiKey"])
        XCTAssertNil(object["verificationReceipt"])
        XCTAssertNil(object["credentialFingerprint"])
    }

    func testReplacingAudioPreservesSpeechMetadata() {
        let entry = TranscriptionHistoryEntry(
            rawText: "raw",
            processedText: "processed",
            appName: "Editor",
            windowTitle: "Document",
            wasAIProcessed: false,
            speechProvider: "soniox",
            speechModel: "stt-rt-v5"
        )
        let audio = DictationAudioMetadata(
            fileName: "dictation.wav",
            durationMilliseconds: 250,
            byteCount: 8000,
            sampleRate: 16_000,
            channels: 1,
            model: "stt-rt-v5"
        )

        let replaced = entry.replacingAudio(audio)

        XCTAssertEqual(replaced.speechProvider, "soniox")
        XCTAssertEqual(replaced.speechModel, "stt-rt-v5")
    }

    func testDiscardAndFailedSonioxSessionsAddNoHistory() throws {
        let historyStore = TranscriptionHistoryStore.shared
        let originalHistory = historyStore.makeBackupPayload()
        defer { historyStore.restore(from: originalHistory) }
        historyStore.restore(from: [])
        let configuration = try XCTUnwrap(RecordingSpeechConfiguration(
            inputSourceID: nil,
            localeIdentifier: "en-US",
            model: .sonioxV5,
            languageBinding: .soniox(.init(languageCode: "en", isStrict: true, region: .global))
        ))

        let discardedCoordinator = DictationSessionCoordinator()
        let discardedSession = discardedCoordinator.begin(
            activationStyle: .toggle,
            speechConfiguration: configuration
        )
        XCTAssertTrue(discardedCoordinator.cancel(for: discardedSession.id))

        let failedCoordinator = DictationSessionCoordinator()
        let failedSession = failedCoordinator.begin(
            activationStyle: .toggle,
            speechConfiguration: configuration
        )
        let failure = ASRRecordingFailure(
            sessionID: failedSession.id,
            category: .temporaryService,
            title: "Soniox Temporarily Unavailable",
            message: "Check the network connection and try again.",
            requestID: nil
        )
        XCTAssertTrue(DictationRecordingFailureHandler.handle(
            failure,
            coordinator: failedCoordinator,
            cancelFinalization: {},
            hideOverlay: {},
            showFailure: { _ in }
        ))

        XCTAssertEqual(historyStore.makeBackupPayload(), [])
        XCTAssertEqual(discardedCoordinator.outputOutcome(for: discardedSession.id), .discarded)
        XCTAssertEqual(failedCoordinator.outputOutcome(for: failedSession.id), .discarded)
    }

    func testBackupJSONContainsNoSonioxCredentialOrVerificationReceipt() throws {
        let credential = "secret-soniox-key"
        let receipt = SonioxVerificationReceipt.make(apiKey: credential, region: .global)
        let settings = SettingsStore.shared
        let originalReceipt = settings.sonioxVerificationReceipt
        defer { settings.sonioxVerificationReceipt = originalReceipt }
        settings.sonioxVerificationReceipt = receipt
        let entry = TranscriptionHistoryEntry(
            rawText: "raw",
            processedText: "processed",
            appName: "Editor",
            windowTitle: "Document",
            wasAIProcessed: false,
            speechProvider: "soniox",
            speechModel: "stt-rt-v5"
        )
        let document = AppBackupDocument(
            schemaVersion: .current,
            appVersion: "test",
            exportedAt: Date(timeIntervalSince1970: 0),
            settings: settings.makeBackupPayload(),
            promptProfiles: [],
            appPromptBindings: [],
            transcriptionHistory: [entry],
            pronunciationProfiles: []
        )

        let encoded = try XCTUnwrap(String(
            data: BackupService.shared.encode(document),
            encoding: .utf8
        ))

        XCTAssertFalse(encoded.contains(credential))
        XCTAssertFalse(encoded.contains(receipt.credentialFingerprint))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("receipt"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("fingerprint"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("requestID"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("endpoint"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("server-message"))
    }

    func testStreamingTerminalErrorClearsPartialAndReportsOwnedSessionOnce() throws {
        let coordinator = DictationSessionCoordinator()
        let configuration = try XCTUnwrap(RecordingSpeechConfiguration(
            inputSourceID: nil,
            localeIdentifier: "ja-JP",
            model: .sonioxV5,
            languageBinding: .soniox(.init(languageCode: "ja", isStrict: true, region: .japan))
        ))
        let session = coordinator.begin(activationStyle: .toggle, speechConfiguration: configuration)
        let failure = ASRRecordingFailure(
            sessionID: session.id,
            category: .temporaryService,
            title: "Soniox Temporarily Unavailable",
            message: "Check the network connection and try again.",
            requestID: "request_42"
        )
        var partial = "partial draft"
        var cancellationCount = 0
        var shownCount = 0

        XCTAssertTrue(DictationRecordingFailureHandler.handle(
            failure,
            coordinator: coordinator,
            cancelFinalization: {
                cancellationCount += 1
                partial.removeAll()
            },
            hideOverlay: {},
            showFailure: { _ in shownCount += 1 }
        ))
        XCTAssertFalse(DictationRecordingFailureHandler.handle(
            failure,
            coordinator: coordinator,
            cancelFinalization: {
                cancellationCount += 1
                partial.removeAll()
            },
            hideOverlay: {},
            showFailure: { _ in shownCount += 1 }
        ))

        XCTAssertTrue(partial.isEmpty)
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(shownCount, 1)
        XCTAssertEqual(coordinator.state(for: session.id), .cancelled)
        XCTAssertEqual(coordinator.outputOutcome(for: session.id), .discarded)
        XCTAssertFalse(coordinator.claimOutputDelivery(for: session.id))
    }

    func testFailureHandlerCallbackOrdersCancellationBeforeDismissal() throws {
        let coordinator = DictationSessionCoordinator()
        let configuration = try XCTUnwrap(RecordingSpeechConfiguration(
            inputSourceID: nil,
            localeIdentifier: "en-US",
            model: .sonioxV5,
            languageBinding: .soniox(.init(languageCode: "en", isStrict: true, region: .global))
        ))
        let session = coordinator.begin(activationStyle: .toggle, speechConfiguration: configuration)
        let failure = ASRRecordingFailure(
            sessionID: session.id,
            category: .temporaryService,
            title: "Soniox Temporarily Unavailable",
            message: "Check the network connection and try again.",
            requestID: nil
        )
        var events: [String] = []

        XCTAssertTrue(DictationRecordingFailureHandler.handle(
            failure,
            coordinator: coordinator,
            cancelFinalization: {
                XCTAssertEqual(coordinator.state(for: session.id), .cancelled)
                events.append("cancel")
            },
            hideOverlay: {
                XCTAssertEqual(coordinator.state(for: session.id), .cancelled)
                events.append("hide")
            },
            showFailure: { _ in
                XCTAssertEqual(coordinator.state(for: session.id), .cancelled)
                events.append("show")
            }
        ))

        XCTAssertEqual(events, ["cancel", "hide", "show"])
        XCTAssertNil(coordinator.currentSession)
    }

    func testStaleSessionErrorCannotCancelOrPublishIntoNewSession() throws {
        let coordinator = DictationSessionCoordinator()
        let configuration = try XCTUnwrap(RecordingSpeechConfiguration(
            inputSourceID: nil,
            localeIdentifier: "en-US",
            model: .sonioxV5,
            languageBinding: .soniox(.init(languageCode: "en", isStrict: true, region: .global))
        ))
        let staleSession = coordinator.begin(activationStyle: .toggle, speechConfiguration: configuration)
        let currentSession = coordinator.begin(activationStyle: .toggle, speechConfiguration: configuration)
        let failure = ASRRecordingFailure(
            sessionID: staleSession.id,
            category: .temporaryService,
            title: "Soniox Temporarily Unavailable",
            message: "Check the network connection and try again.",
            requestID: nil
        )
        var callbackCount = 0

        XCTAssertFalse(DictationRecordingFailureHandler.handle(
            failure,
            coordinator: coordinator,
            cancelFinalization: { callbackCount += 1 },
            hideOverlay: { callbackCount += 1 },
            showFailure: { _ in callbackCount += 1 }
        ))

        XCTAssertEqual(callbackCount, 0)
        XCTAssertEqual(coordinator.currentSession?.id, currentSession.id)
        XCTAssertTrue(coordinator.isCapturing(currentSession.id))
        XCTAssertFalse(coordinator.claimOutputDelivery(for: staleSession.id))
        XCTAssertNil(coordinator.outputOutcome(for: staleSession.id))
    }

    func testFailedSonioxSessionDoesNotForceAudioHistoryPersistence() throws {
        let coordinator = DictationSessionCoordinator()
        let configuration = try XCTUnwrap(RecordingSpeechConfiguration(
            inputSourceID: nil,
            localeIdentifier: "en-US",
            model: .sonioxV5,
            languageBinding: .soniox(.init(languageCode: "en", isStrict: true, region: .global))
        ))
        let session = coordinator.begin(activationStyle: .toggle, speechConfiguration: configuration)
        let failure = ASRRecordingFailure(
            sessionID: session.id,
            category: .temporaryService,
            title: "Soniox Temporarily Unavailable",
            message: "Check the network connection and try again.",
            requestID: nil
        )

        XCTAssertTrue(DictationRecordingFailureHandler.handle(
            failure,
            coordinator: coordinator,
            cancelFinalization: {},
            hideOverlay: {},
            showFailure: { _ in }
        ))
        XCTAssertEqual(coordinator.outputOutcome(for: session.id), .discarded)
        XCTAssertFalse(coordinator.claimOutputDelivery(for: session.id))
    }
}

@MainActor
final class DictationSessionCoordinatorTests: XCTestCase {
    private var englishConfiguration: RecordingSpeechConfiguration {
        guard let configuration = RecordingSpeechConfiguration(
            inputSourceID: "com.apple.keylayout.US",
            localeIdentifier: "en-US",
            model: .appleSpeech,
            languageBinding: .appleSpeech(localeIdentifier: "en-US")
        ) else {
            preconditionFailure("The English test configuration must remain valid")
        }
        return configuration
    }

    func testCoordinatorRecordsTerminalOutputOutcome() throws {
        let coordinator = DictationSessionCoordinator()
        let session = coordinator.begin(
            activationStyle: .toggle,
            speechConfiguration: self.englishConfiguration
        )

        XCTAssertTrue(coordinator.hasActiveSession)
        XCTAssertTrue(coordinator.beginFinalization(for: session.id))
        let gate = try XCTUnwrap(coordinator.claimOutputDeliveryGate(for: session.id))
        XCTAssertTrue(gate.commit())
        XCTAssertTrue(coordinator.complete(for: session.id, outcome: .copied))

        XCTAssertEqual(coordinator.state(for: session.id), .completed)
        XCTAssertEqual(coordinator.outputOutcome(for: session.id), .copied)
        XCTAssertFalse(coordinator.hasActiveSession)
        XCTAssertNil(coordinator.currentSession)
    }

    func testDiscardRecordsOutcomeAndBlocksDelivery() {
        let coordinator = DictationSessionCoordinator()
        let session = coordinator.begin(
            activationStyle: .toggle,
            speechConfiguration: self.englishConfiguration
        )

        XCTAssertEqual(coordinator.requestExit(.discard, for: session.id), .discard)

        XCTAssertEqual(coordinator.outputOutcome(for: session.id), .discarded)
        XCTAssertFalse(coordinator.claimOutputDelivery(for: session.id))
        XCTAssertFalse(coordinator.hasActiveSession)
        XCTAssertNil(coordinator.currentSession)
    }

    func testEmptyFinalizationCanCompleteWithoutDelivery() {
        let coordinator = DictationSessionCoordinator()
        let session = coordinator.begin(
            activationStyle: .toggle,
            speechConfiguration: self.englishConfiguration
        )

        XCTAssertTrue(coordinator.beginFinalization(for: session.id))
        XCTAssertTrue(coordinator.completeWithoutDelivery(for: session.id))

        XCTAssertEqual(coordinator.state(for: session.id), .completed)
        XCTAssertNil(coordinator.outputOutcome(for: session.id))
    }

    func testBeginFreezesSpeechConfigurationForSession() {
        let coordinator = DictationSessionCoordinator()

        let session = coordinator.begin(
            activationStyle: .toggle,
            speechConfiguration: self.englishConfiguration
        )

        XCTAssertEqual(session.speechConfiguration, self.englishConfiguration)
        XCTAssertEqual(coordinator.state(for: session.id), .capturing)
        XCTAssertTrue(coordinator.isCapturing(session.id))
    }

    func testCapturingSessionCanUpdateSpeechConfigurationForLiveInputSourceSwitch() throws {
        let coordinator = DictationSessionCoordinator()
        let session = coordinator.begin(
            activationStyle: .toggle,
            speechConfiguration: self.englishConfiguration
        )
        let japaneseConfiguration = try XCTUnwrap(RecordingSpeechConfiguration(
            inputSourceID: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",
            localeIdentifier: "ja-JP",
            model: .appleSpeech,
            languageBinding: .appleSpeech(localeIdentifier: "ja-JP")
        ))

        XCTAssertTrue(coordinator.updateSpeechConfiguration(japaneseConfiguration, for: session.id))
        XCTAssertEqual(coordinator.currentSession?.speechConfiguration, japaneseConfiguration)
        XCTAssertTrue(coordinator.isCapturing(session.id))
    }

    func testSpeechConfigurationCannotChangeAfterFinalizationStarts() throws {
        let coordinator = DictationSessionCoordinator()
        let session = coordinator.begin(
            activationStyle: .toggle,
            speechConfiguration: self.englishConfiguration
        )
        let japaneseConfiguration = try XCTUnwrap(RecordingSpeechConfiguration(
            inputSourceID: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",
            localeIdentifier: "ja-JP",
            model: .appleSpeech,
            languageBinding: .appleSpeech(localeIdentifier: "ja-JP")
        ))

        XCTAssertTrue(coordinator.beginFinalization(for: session.id))
        XCTAssertFalse(coordinator.updateSpeechConfiguration(japaneseConfiguration, for: session.id))
        XCTAssertEqual(coordinator.currentSession?.speechConfiguration, self.englishConfiguration)
    }

    func testAutomaticTapCanResolveCapturingSessionToToggle() {
        let coordinator = DictationSessionCoordinator()
        let session = coordinator.begin(
            activationStyle: .pushToTalk,
            speechConfiguration: self.englishConfiguration
        )

        XCTAssertTrue(coordinator.resolveActivationStyle(.toggle, for: session.id))
        XCTAssertEqual(coordinator.currentSession?.activationStyle, .toggle)
        XCTAssertEqual(coordinator.requestExit(.discard, for: session.id), .discard)
    }

    func testActivationStyleCannotChangeAfterFinalizationStarts() {
        let coordinator = DictationSessionCoordinator()
        let session = coordinator.begin(
            activationStyle: .pushToTalk,
            speechConfiguration: self.englishConfiguration
        )
        XCTAssertTrue(coordinator.beginFinalization(for: session.id))

        XCTAssertFalse(coordinator.resolveActivationStyle(.toggle, for: session.id))
        XCTAssertEqual(coordinator.currentSession?.activationStyle, .pushToTalk)
    }

    func testAuxiliarySessionCanDisableToggleExitPoliciesWhileRemainingScoped() {
        let coordinator = DictationSessionCoordinator()
        let session = coordinator.begin(
            activationStyle: .toggle,
            speechConfiguration: self.englishConfiguration,
            exitPoliciesEnabled: false
        )

        XCTAssertTrue(coordinator.hasActiveSession)
        XCTAssertEqual(coordinator.requestExit(.discard, for: session.id), .ignore)
        XCTAssertEqual(coordinator.requestExit(.paste, for: session.id), .ignore)
        XCTAssertTrue(coordinator.isCapturing(session.id))
    }

    func testLiveModeSwitchesUpdateDictationExitPolicyEligibilityBothWays() {
        let coordinator = DictationSessionCoordinator()
        let session = coordinator.begin(
            activationStyle: .toggle,
            speechConfiguration: self.englishConfiguration,
            exitPoliciesEnabled: false
        )

        XCTAssertTrue(coordinator.setExitPoliciesEnabled(true, for: session.id))
        XCTAssertEqual(coordinator.requestExit(.paste, for: session.id), .finalize)
        XCTAssertTrue(coordinator.setExitPoliciesEnabled(false, for: session.id))
        XCTAssertEqual(coordinator.requestExit(.discard, for: session.id), .ignore)
        XCTAssertTrue(coordinator.isCapturing(session.id))
    }

    func testFinalizationCanOnlyBeginOnce() {
        let coordinator = DictationSessionCoordinator()
        let session = coordinator.begin(
            activationStyle: .toggle,
            speechConfiguration: self.englishConfiguration
        )

        XCTAssertTrue(coordinator.beginFinalization(for: session.id))
        XCTAssertFalse(coordinator.beginFinalization(for: session.id))
        XCTAssertEqual(coordinator.state(for: session.id), .finalizing)
        XCTAssertTrue(coordinator.canContinueFinalization(for: session.id))
    }

    func testDiscardAfterCallbackAdmissionPreventsLateOutputDelivery() {
        let coordinator = DictationSessionCoordinator()
        let session = coordinator.begin(
            activationStyle: .toggle,
            speechConfiguration: self.englishConfiguration
        )
        XCTAssertTrue(coordinator.beginFinalization(for: session.id))
        XCTAssertTrue(coordinator.canContinueFinalization(for: session.id))

        XCTAssertEqual(coordinator.requestExit(.discard, for: session.id), .discard)
        XCTAssertFalse(coordinator.claimOutputDelivery(for: session.id))
        XCTAssertEqual(coordinator.state(for: session.id), .cancelled)
        XCTAssertFalse(coordinator.complete(for: session.id))
    }

    func testClaimedOutputDeliveryHasSingleTerminalWinner() throws {
        let coordinator = DictationSessionCoordinator()
        let session = coordinator.begin(
            activationStyle: .toggle,
            speechConfiguration: self.englishConfiguration
        )
        XCTAssertTrue(coordinator.beginFinalization(for: session.id))

        let gate = try XCTUnwrap(coordinator.claimOutputDeliveryGate(for: session.id))
        XCTAssertFalse(coordinator.claimOutputDelivery(for: session.id))
        XCTAssertEqual(coordinator.requestExit(.discard, for: session.id), .discard)
        XCTAssertFalse(gate.commit())
        XCTAssertFalse(coordinator.complete(for: session.id))
        XCTAssertFalse(coordinator.complete(for: session.id))
        XCTAssertEqual(coordinator.state(for: session.id), .cancelled)
        XCTAssertFalse(coordinator.canContinueFinalization(for: session.id))
    }

    func testCommittedOutputDeliveryWinsAgainstLateDiscard() throws {
        let coordinator = DictationSessionCoordinator()
        let session = coordinator.begin(
            activationStyle: .toggle,
            speechConfiguration: self.englishConfiguration
        )
        XCTAssertTrue(coordinator.beginFinalization(for: session.id))
        let gate = try XCTUnwrap(coordinator.claimOutputDeliveryGate(for: session.id))

        XCTAssertTrue(gate.commit())
        XCTAssertEqual(coordinator.requestExit(.discard, for: session.id), .ignore)
        XCTAssertTrue(coordinator.complete(for: session.id))
        XCTAssertEqual(coordinator.state(for: session.id), .completed)
    }

    func testPasteExitDeduplicatesSimultaneousTerminalEvents() {
        let coordinator = DictationSessionCoordinator()
        let session = coordinator.begin(
            activationStyle: .toggle,
            speechConfiguration: self.englishConfiguration
        )

        XCTAssertEqual(coordinator.requestExit(.paste, for: session.id), .finalize)
        XCTAssertEqual(coordinator.requestExit(.paste, for: session.id), .finalize)
        XCTAssertTrue(coordinator.beginFinalization(for: session.id))
        XCTAssertEqual(coordinator.requestExit(.paste, for: session.id), .ignore)
        XCTAssertEqual(coordinator.requestExit(.discard, for: session.id), .discard)
        XCTAssertEqual(coordinator.requestExit(.discard, for: session.id), .ignore)
    }

    func testDoNothingDoesNotTerminateToggleCapture() {
        let coordinator = DictationSessionCoordinator()
        let toggleSession = coordinator.begin(
            activationStyle: .toggle,
            speechConfiguration: self.englishConfiguration
        )

        XCTAssertEqual(coordinator.requestExit(.doNothing, for: toggleSession.id), .ignore)
        XCTAssertTrue(coordinator.isCapturing(toggleSession.id))
    }

    func testEveryPushToTalkExitPolicyIsIgnored() {
        let coordinator = DictationSessionCoordinator()

        let pushToTalkSession = coordinator.begin(
            activationStyle: .pushToTalk,
            speechConfiguration: self.englishConfiguration
        )
        for action in DictationExitAction.allCases {
            XCTAssertEqual(coordinator.requestExit(action, for: pushToTalkSession.id), .ignore)
        }
        XCTAssertTrue(coordinator.isCapturing(pushToTalkSession.id))
    }

    func testStaleSessionIDCannotMutateCurrentSession() {
        let coordinator = DictationSessionCoordinator()
        let current = coordinator.begin(
            activationStyle: .toggle,
            speechConfiguration: self.englishConfiguration
        )
        let staleID = RecordingSessionID()

        XCTAssertFalse(coordinator.beginFinalization(for: staleID))
        XCTAssertFalse(coordinator.cancel(for: staleID))
        XCTAssertFalse(coordinator.claimOutputDelivery(for: staleID))
        XCTAssertFalse(coordinator.complete(for: staleID))
        for action in DictationExitAction.allCases {
            XCTAssertEqual(coordinator.requestExit(action, for: staleID), .ignore)
        }
        XCTAssertTrue(coordinator.isCapturing(current.id))
    }

    func testStartingNewSessionInvalidatesPreviousSession() {
        let coordinator = DictationSessionCoordinator()
        let first = coordinator.begin(
            activationStyle: .toggle,
            speechConfiguration: self.englishConfiguration
        )
        let second = coordinator.begin(
            activationStyle: .toggle,
            speechConfiguration: self.englishConfiguration
        )

        XCTAssertNil(coordinator.state(for: first.id))
        XCTAssertTrue(coordinator.isCapturing(second.id))
    }

    func testRejectsContradictoryAppleSpeechLocaleConfiguration() {
        XCTAssertNil(RecordingSpeechConfiguration(
            inputSourceID: "com.apple.keylayout.German",
            localeIdentifier: "de-DE",
            model: .appleSpeech,
            languageBinding: .appleSpeech(localeIdentifier: "en-US")
        ))
    }

    func testRejectsIncompatibleSpeechModelAndLanguageBindings() {
        let incompatiblePairs: [(SettingsStore.SpeechModel, VoiceEngineLanguageRoute.LanguageBinding)] = [
            (.whisperTiny, .appleSpeech(localeIdentifier: "en-US")),
            (.appleSpeech, .whisper(languageCode: "en")),
            (.cohereTranscribeSixBit, .automatic),
            (.parakeetTDT, .cohere(.english)),
            (.nemotronOffline, .automatic),
            (.sonioxV5, .automatic),
            (.appleSpeech, .soniox(.init(languageCode: "en", isStrict: true, region: .global))),
        ]

        for (model, binding) in incompatiblePairs {
            XCTAssertNil(
                RecordingSpeechConfiguration(
                    inputSourceID: nil,
                    localeIdentifier: "en-US",
                    model: model,
                    languageBinding: binding
                ),
                "Expected \(model) with \(binding) to be rejected"
            )
        }
    }
}

@MainActor
final class WorkflowSettingsTests: XCTestCase {
    private let modelAssignmentsKey = "SpeechModelAssignmentsByInputSourceID"
    private let escapeExitActionKey = "EscapeExitAction"
    private let outsideClickExitActionKey = "OutsideClickExitAction"
    private let copyWhenNoWritableInputFocusedKey = "CopyWhenNoWritableInputFocused"
    private let transcriptionPreviewMaxLinesKey = "TranscriptionPreviewMaxLines"
    private let sonioxLanguageModeKey = "SonioxLanguageMode"
    private let sonioxRegionKey = "SonioxRegion"
    private let sonioxReceiptKey = "SonioxVerificationReceipt"

    func testPerInputSourceModelAssignmentsRoundTripWithoutPruningMissingSources() {
        self.withRestoredDefaults(keys: [self.modelAssignmentsKey]) {
            let settings = SettingsStore.shared
            let assignments: [String: SettingsStore.SpeechModel] = [
                "com.apple.keylayout.US": .appleSpeech,
                "com.example.disabled-ime": .whisperSmall,
            ]

            settings.speechModelAssignmentsByInputSourceID = assignments

            XCTAssertEqual(settings.speechModelAssignmentsByInputSourceID, assignments)
        }
    }

    func testPerInputSourceModelAssignmentsIgnoreUnknownModelsButKeepValidEntries() throws {
        try self.withRestoredDefaults(keys: [self.modelAssignmentsKey]) {
            let rawAssignments = [
                "com.apple.keylayout.US": SettingsStore.SpeechModel.appleSpeech.rawValue,
                "com.example.future-ime": "future-model",
            ]
            try UserDefaults.standard.set(
                JSONEncoder().encode(rawAssignments),
                forKey: self.modelAssignmentsKey
            )

            XCTAssertEqual(
                SettingsStore.shared.speechModelAssignmentsByInputSourceID,
                ["com.apple.keylayout.US": .appleSpeech]
            )
        }
    }

    func testUpdatingOneModelAssignmentPreservesUnknownFutureModels() throws {
        try self.withRestoredDefaults(keys: [self.modelAssignmentsKey]) {
            let rawAssignments = [
                "com.apple.keylayout.US": SettingsStore.SpeechModel.appleSpeech.rawValue,
                "com.example.future-ime": "future-model",
            ]
            try UserDefaults.standard.set(
                JSONEncoder().encode(rawAssignments),
                forKey: self.modelAssignmentsKey
            )

            SettingsStore.shared.setSpeechModelAssignment(
                .whisperSmall,
                forInputSourceID: "com.apple.keylayout.US"
            )

            let data = try XCTUnwrap(UserDefaults.standard.data(forKey: self.modelAssignmentsKey))
            let stored = try JSONDecoder().decode([String: String].self, from: data)
            XCTAssertEqual(stored["com.apple.keylayout.US"], SettingsStore.SpeechModel.whisperSmall.rawValue)
            XCTAssertEqual(stored["com.example.future-ime"], "future-model")
        }
    }

    func testExitPoliciesDefaultToPasteAndPersistIndependently() {
        self.withRestoredDefaults(keys: [self.escapeExitActionKey, self.outsideClickExitActionKey]) {
            let settings = SettingsStore.shared
            UserDefaults.standard.removeObject(forKey: self.escapeExitActionKey)
            UserDefaults.standard.removeObject(forKey: self.outsideClickExitActionKey)

            XCTAssertEqual(settings.escapeExitAction, .paste)
            XCTAssertEqual(settings.outsideClickExitAction, .paste)

            settings.escapeExitAction = .discard
            settings.outsideClickExitAction = .doNothing

            XCTAssertEqual(settings.escapeExitAction, .discard)
            XCTAssertEqual(settings.outsideClickExitAction, .doNothing)
        }
    }

    func testCopyWhenNoWritableInputFocusedDefaultsEnabledAndPersists() {
        self.withRestoredDefaults(keys: [self.copyWhenNoWritableInputFocusedKey]) {
            let settings = SettingsStore.shared
            UserDefaults.standard.removeObject(forKey: self.copyWhenNoWritableInputFocusedKey)

            XCTAssertTrue(settings.copyWhenNoWritableInputFocused)

            settings.copyWhenNoWritableInputFocused = false

            XCTAssertFalse(settings.copyWhenNoWritableInputFocused)
        }
    }

    func testTranscriptionPreviewMaxLinesClampsAndPersists() {
        self.withRestoredDefaults(keys: [self.transcriptionPreviewMaxLinesKey]) {
            let settings = SettingsStore.shared
            UserDefaults.standard.removeObject(forKey: self.transcriptionPreviewMaxLinesKey)

            XCTAssertEqual(settings.transcriptionPreviewMaxLines, SettingsStore.defaultTranscriptionPreviewMaxLines)

            settings.transcriptionPreviewMaxLines = 0
            XCTAssertEqual(settings.transcriptionPreviewMaxLines, SettingsStore.transcriptionPreviewMaxLinesRange.lowerBound)

            settings.transcriptionPreviewMaxLines = 99
            XCTAssertEqual(settings.transcriptionPreviewMaxLines, SettingsStore.transcriptionPreviewMaxLinesRange.upperBound)
        }
    }

    func testWorkflowSettingsAreIncludedInBackupPayload() {
        self.withRestoredDefaults(keys: [
            self.modelAssignmentsKey,
            self.escapeExitActionKey,
            self.outsideClickExitActionKey,
            self.copyWhenNoWritableInputFocusedKey,
        ]) {
            let settings = SettingsStore.shared
            let assignments = ["com.apple.keylayout.US": SettingsStore.SpeechModel.appleSpeech]
            settings.speechModelAssignmentsByInputSourceID = assignments
            settings.escapeExitAction = .discard
            settings.outsideClickExitAction = .doNothing
            settings.copyWhenNoWritableInputFocused = false

            let payload = settings.makeBackupPayload()

            XCTAssertEqual(payload.speechModelAssignmentsByInputSourceID, assignments)
            XCTAssertEqual(payload.escapeExitAction, .discard)
            XCTAssertEqual(payload.outsideClickExitAction, .doNothing)
            XCTAssertEqual(payload.copyWhenNoWritableInputFocused, false)
        }
    }

    func testLegacyBackupWithoutWorkflowSettingsStillDecodes() throws {
        let payload = SettingsStore.shared.makeBackupPayload()
        let encoded = try JSONEncoder().encode(payload)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "speechModelAssignmentsByInputSourceID")
        object.removeValue(forKey: "escapeExitAction")
        object.removeValue(forKey: "outsideClickExitAction")
        object.removeValue(forKey: "copyWhenNoWritableInputFocused")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SettingsBackupPayload.self, from: legacyData)

        XCTAssertNil(decoded.speechModelAssignmentsByInputSourceID)
        XCTAssertNil(decoded.escapeExitAction)
        XCTAssertNil(decoded.outsideClickExitAction)
        XCTAssertNil(decoded.copyWhenNoWritableInputFocused)
    }

    func testLegacyBackupWithoutSonioxSettingsStillDecodes() throws {
        let encoded = try JSONEncoder().encode(SettingsStore.shared.makeBackupPayload())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "sonioxLanguageModeID")
        object.removeValue(forKey: "sonioxRegionID")

        let decoded = try JSONDecoder().decode(
            SettingsBackupPayload.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(decoded.sonioxLanguageModeID)
        XCTAssertNil(decoded.sonioxRegionID)
    }

    func testLegacyBackupWithoutPreviewLineLimitStillDecodes() throws {
        let encoded = try JSONEncoder().encode(SettingsStore.shared.makeBackupPayload())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "transcriptionPreviewMaxLines")

        let decoded = try JSONDecoder().decode(
            SettingsBackupPayload.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(decoded.transcriptionPreviewMaxLines)
    }

    func testBackupIncludesOnlyNonSecretSonioxModeAndRegion() throws {
        try self.withRestoredDefaults(keys: [
            self.sonioxLanguageModeKey,
            self.sonioxRegionKey,
            self.sonioxReceiptKey,
        ]) {
            let settings = SettingsStore.shared
            settings.sonioxLanguageMode = .preferCurrentInputSource
            settings.sonioxRegion = .japan
            settings.sonioxVerificationReceipt = .make(apiKey: "never-export", region: .japan)

            let payload = settings.makeBackupPayload()
            let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(payload), encoding: .utf8))

            XCTAssertEqual(payload.sonioxLanguageModeID, "preferCurrentInputSource")
            XCTAssertEqual(payload.sonioxRegionID, "japan")
            XCTAssertFalse(encoded.contains("never-export"))
            XCTAssertFalse(encoded.localizedCaseInsensitiveContains("receipt"))
            XCTAssertFalse(encoded.localizedCaseInsensitiveContains("fingerprint"))
        }
    }

    func testUnknownBackupSonioxValuesRestoreSafeDefaults() throws {
        try self.withRestoredDefaults(keys: [self.sonioxLanguageModeKey, self.sonioxRegionKey]) {
            let settings = SettingsStore.shared
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(settings.makeBackupPayload()))
                    as? [String: Any]
            )
            object["sonioxLanguageModeID"] = "future-mode"
            object["sonioxRegionID"] = "future-region"
            let payload = try JSONDecoder().decode(
                SettingsBackupPayload.self,
                from: JSONSerialization.data(withJSONObject: object)
            )

            settings.restore(from: payload)

            XCTAssertEqual(settings.sonioxLanguageMode, .currentInputSourceOnly)
            XCTAssertEqual(settings.sonioxRegion, .global)
        }
    }

    private func withRestoredDefaults(keys: [String], run: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let snapshot = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            defaults.object(forKey: key).map { (key, $0) }
        })

        defer {
            for key in keys {
                if let value = snapshot[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        try run()
    }
}

@MainActor
final class DictationOutputRoutingTests: XCTestCase {
    func testWritableExternalInputTypesWithoutPersistentClipboardMutation() {
        let decision = DictationOutputRoutingDecision.resolve(
            shouldPersistOutputs: true,
            target: .writableExternal,
            alwaysCopyToClipboard: false,
            copyWhenNoWritableInputFocused: true
        )

        XCTAssertEqual(decision, .init(
            shouldTypeExternally: true,
            shouldCopyToClipboard: false,
            outcome: .typed
        ))
    }

    func testNoWritableInputCopiesOnlyWhenFallbackEnabled() {
        let copied = DictationOutputRoutingDecision.resolve(
            shouldPersistOutputs: true,
            target: .unavailable,
            alwaysCopyToClipboard: false,
            copyWhenNoWritableInputFocused: true
        )
        let noTarget = DictationOutputRoutingDecision.resolve(
            shouldPersistOutputs: true,
            target: .unavailable,
            alwaysCopyToClipboard: false,
            copyWhenNoWritableInputFocused: false
        )

        XCTAssertEqual(copied.outcome, .copied)
        XCTAssertTrue(copied.shouldCopyToClipboard)
        XCTAssertEqual(noTarget.outcome, .noTarget)
        XCTAssertFalse(noTarget.shouldCopyToClipboard)
        XCTAssertFalse(noTarget.shouldTypeExternally)
    }

    func testExplicitAlwaysCopySettingRemainsIndependentFromFocusedInputFallback() {
        let decision = DictationOutputRoutingDecision.resolve(
            shouldPersistOutputs: true,
            target: .writableExternal,
            alwaysCopyToClipboard: true,
            copyWhenNoWritableInputFocused: false
        )

        XCTAssertEqual(decision.outcome, .typed)
        XCTAssertTrue(decision.shouldTypeExternally)
        XCTAssertTrue(decision.shouldCopyToClipboard)
    }

    func testInAppEditorCountsAsTypedWithoutExternalInsertion() {
        let decision = DictationOutputRoutingDecision.resolve(
            shouldPersistOutputs: true,
            target: .inAppEditor,
            alwaysCopyToClipboard: false,
            copyWhenNoWritableInputFocused: true
        )

        XCTAssertEqual(decision.outcome, .typed)
        XCTAssertFalse(decision.shouldTypeExternally)
        XCTAssertFalse(decision.shouldCopyToClipboard)
    }

    func testSandboxSuppressesEveryPersistentOutput() {
        let decision = DictationOutputRoutingDecision.resolve(
            shouldPersistOutputs: false,
            target: .writableExternal,
            alwaysCopyToClipboard: true,
            copyWhenNoWritableInputFocused: true
        )

        XCTAssertNil(decision.outcome)
        XCTAssertFalse(decision.shouldTypeExternally)
        XCTAssertFalse(decision.shouldCopyToClipboard)
    }

    func testWritableInputAssessmentRejectsSecureDisabledAndStaticTargets() {
        XCTAssertFalse(FocusedInputAssessment(
            role: "AXTextField",
            subrole: "AXSecureTextField",
            isEnabled: true,
            isEditable: true,
            isValueSettable: true,
            isSelectedTextSettable: true,
            isSecureInputEnabled: false
        ).isWritable)
        XCTAssertFalse(FocusedInputAssessment(
            role: "AXTextArea",
            subrole: nil,
            isEnabled: false,
            isEditable: true,
            isValueSettable: true,
            isSelectedTextSettable: true,
            isSecureInputEnabled: false
        ).isWritable)
        XCTAssertFalse(FocusedInputAssessment(
            role: "AXStaticText",
            subrole: nil,
            isEnabled: true,
            isEditable: false,
            isValueSettable: false,
            isSelectedTextSettable: false,
            isSecureInputEnabled: false
        ).isWritable)
        XCTAssertFalse(FocusedInputAssessment(
            role: "AXTextField",
            subrole: nil,
            isEnabled: true,
            isEditable: false,
            isValueSettable: false,
            isSelectedTextSettable: false,
            isSecureInputEnabled: false
        ).isWritable)
        XCTAssertFalse(FocusedInputAssessment(
            role: "AXTextField",
            subrole: nil,
            isEnabled: true,
            isEditable: true,
            isValueSettable: true,
            isSelectedTextSettable: true,
            isSecureInputEnabled: true
        ).isWritable)
    }

    func testWritableInputAssessmentAcceptsSemanticAndSettableTextTargets() {
        XCTAssertTrue(FocusedInputAssessment(
            role: "AXTextArea",
            subrole: nil,
            isEnabled: true,
            isEditable: nil,
            isValueSettable: false,
            isSelectedTextSettable: false,
            isSecureInputEnabled: false
        ).isWritable)
        XCTAssertTrue(FocusedInputAssessment(
            role: "AXWebArea",
            subrole: nil,
            isEnabled: true,
            isEditable: true,
            isValueSettable: false,
            isSelectedTextSettable: false,
            isSecureInputEnabled: false
        ).isWritable)
        XCTAssertTrue(FocusedInputAssessment(
            role: "AXGroup",
            subrole: nil,
            isEnabled: true,
            isEditable: nil,
            isValueSettable: false,
            isSelectedTextSettable: true,
            isSecureInputEnabled: false
        ).isWritable)
    }

    func testHistoryOutputOutcomeDefaultsForLegacyPayloadAndRoundTrips() throws {
        let entry = TranscriptionHistoryEntry(
            rawText: "raw",
            processedText: "processed",
            appName: "Editor",
            windowTitle: "Document",
            wasAIProcessed: false,
            outputOutcome: .copied
        )
        let encoded = try JSONEncoder().encode(entry)
        XCTAssertEqual(try JSONDecoder().decode(TranscriptionHistoryEntry.self, from: encoded).outputOutcome, .copied)

        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyObject.removeValue(forKey: "outputOutcome")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        XCTAssertNil(try JSONDecoder().decode(TranscriptionHistoryEntry.self, from: legacyData).outputOutcome)
    }
}

@MainActor
final class OverlayFailureStateTests: XCTestCase {
    func testCustomNonRetryableMessage() {
        let state = NotchContentState.shared
        defer {
            state.showAIProcessingFailure()
            state.clearAIProcessingFailure()
        }

        state.showAIProcessingFailure(
            message: "Edit Mode cannot be used with Fluid-1",
            canRetry: false
        )

        XCTAssertTrue(state.isAIProcessingFailureVisible)
        XCTAssertEqual(state.aiProcessingFailureMessage, "Edit Mode cannot be used with Fluid-1")
        XCTAssertFalse(state.canRetryAIProcessingFailure)

        state.showAIProcessingFailure()

        XCTAssertEqual(state.aiProcessingFailureMessage, "AI Enhancement failed")
        XCTAssertTrue(state.canRetryAIProcessingFailure)
    }

    func testRecordingSetupFailureOnlyClosesMatchingOwnedSession() throws {
        let coordinator = DictationSessionCoordinator()
        let configuration = try XCTUnwrap(RecordingSpeechConfiguration(
            inputSourceID: nil,
            localeIdentifier: "en-US",
            model: .sonioxV5,
            languageBinding: .soniox(.init(languageCode: "en", isStrict: true, region: .global))
        ))
        let session = coordinator.begin(activationStyle: .toggle, speechConfiguration: configuration)
        var cancellationCount = 0
        var overlayCloseCount = 0
        var shownCopy: SonioxUserFacingErrorCopy?
        let failure = ASRRecordingFailure(
            sessionID: session.id,
            category: .credential,
            title: "Soniox API Key Required",
            message: "Check or re-verify the Soniox API key for the selected region in Voice Engine settings.",
            requestID: nil
        )

        XCTAssertTrue(DictationRecordingFailureHandler.handle(
            failure,
            coordinator: coordinator,
            cancelFinalization: { cancellationCount += 1 },
            hideOverlay: { overlayCloseCount += 1 },
            showFailure: { shownCopy = $0 }
        ))
        XCTAssertEqual(coordinator.state(for: session.id), .cancelled)
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(overlayCloseCount, 1)
        XCTAssertEqual(shownCopy, .init(title: failure.title, message: failure.message))
        XCTAssertEqual(coordinator.outputOutcome(for: session.id), .discarded)
        XCTAssertFalse(coordinator.claimOutputDelivery(for: session.id))

        XCTAssertFalse(DictationRecordingFailureHandler.handle(
            failure,
            coordinator: coordinator,
            cancelFinalization: { cancellationCount += 1 },
            hideOverlay: { overlayCloseCount += 1 },
            showFailure: { shownCopy = $0 }
        ))
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(overlayCloseCount, 1)
    }
}

@MainActor
final class SimpleUpdaterTests: XCTestCase {
    func testUpdateOperationGateAllowsOnlyOneActiveInstall() {
        var gate = UpdateOperationGate()

        XCTAssertTrue(gate.begin())
        XCTAssertTrue(gate.isActive)
        XCTAssertFalse(gate.begin())

        gate.finish()

        XCTAssertFalse(gate.isActive)
        XCTAssertTrue(gate.begin())
    }

    func testForkDisablesReleaseOperationsUntilInfrastructureExists() async {
        do {
            _ = try await SimpleUpdater.shared.checkForUpdate(owner: "altic-dev", repo: "Fluid-oss")
            XCTFail("Release operations must remain disabled for the fork")
        } catch SimpleUpdateError.releaseInfrastructureUnavailable {
            // Expected: no upstream release request is made.
        } catch {
            XCTFail("Unexpected update error: \(error)")
        }
    }
}

final class ForkIdentityTests: XCTestCase {
    func testAppBundleUsesForkIdentity() {
        let appBundle = Bundle(for: AppDelegate.self)

        XCTAssertEqual(appBundle.bundleIdentifier, "com.FluidApp.app")
        XCTAssertEqual(appBundle.fluidAppDisplayName, "MyFluidVoice Debug")
    }
}

@MainActor
final class KeyboardInputSourceRoutingTests: XCTestCase {
    private let sonioxAvailableModels: [SettingsStore.SpeechModel] = [.appleSpeech, .sonioxV5]

    func testInputSourceObservationSuppressesStaleDuplicateAndPublishesTransitions() {
        let english = self.source(id: "com.apple.keylayout.ABC")
        let japanese = self.source(id: "com.google.inputmethod.Japanese.base")
        var state = KeyboardInputSourceObservationState(sourceID: english.id)

        XCTAssertFalse(state.shouldPublish(english))
        XCTAssertTrue(state.shouldPublish(japanese))
        XCTAssertFalse(state.shouldPublish(japanese))
        XCTAssertTrue(state.shouldPublish(english))

        state.synchronize(to: japanese)
        XCTAssertFalse(state.shouldPublish(japanese))
        XCTAssertTrue(state.shouldPublish(english))
    }

    func testInstalledInputSourcesExposeStableUniqueIdentities() {
        let inputSources = KeyboardInputSourceService.installedInputSources()

        XCTAssertFalse(inputSources.isEmpty)
        XCTAssertEqual(Set(inputSources.map(\.id)).count, inputSources.count)
        XCTAssertTrue(inputSources.allSatisfy { !$0.id.isEmpty && !$0.localizedName.isEmpty })
    }

    func testKnownInputSourcesMapToExpectedSpeechLocales() {
        let cases: [(String, String)] = [
            ("com.apple.keylayout.US", "en-US"),
            ("com.apple.keylayout.British", "en-GB"),
            ("com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese", "ja-JP"),
            ("com.apple.inputmethod.Kotoeri.RomajiTyping.Roman", "en-US"),
            ("com.google.inputmethod.Japanese.base", "ja-JP"),
            ("com.google.inputmethod.Japanese.Roman", "en-US"),
            ("com.justsystems.inputmethod.atok33.Japanese", "ja-JP"),
            ("com.justsystems.inputmethod.atok33.Roman", "en-US"),
            ("com.apple.inputmethod.SCIM.ITABC", "zh-CN"),
            ("com.apple.inputmethod.TCIM.Pinyin", "zh-TW"),
            ("com.apple.inputmethod.Korean.2SetKorean", "ko-KR"),
        ]

        for (inputSourceID, expectedLocaleIdentifier) in cases {
            let source = self.source(id: inputSourceID)

            XCTAssertEqual(
                KeyboardInputSourceLocaleResolver.localeIdentifier(
                    for: source,
                    fallbackLocaleIdentifier: "pt-BR"
                ),
                expectedLocaleIdentifier,
                inputSourceID
            )
        }
    }

    func testLocaleResolutionUsesEachRequestedSourcesOwnLanguage() {
        let french = self.source(id: "com.example.FrenchIME", languages: ["fr-CA"])
        let german = self.source(id: "com.example.GermanIME", languages: ["de"])

        XCTAssertEqual(
            KeyboardInputSourceLocaleResolver.localeIdentifier(
                for: french,
                fallbackLocaleIdentifier: "ja-JP"
            ),
            "fr-CA"
        )
        XCTAssertEqual(
            KeyboardInputSourceLocaleResolver.localeIdentifier(
                for: german,
                fallbackLocaleIdentifier: "ja-JP"
            ),
            "de-DE"
        )
    }

    func testLocaleResolutionUsesInjectedLocaleFallbackWhenSourceHasNoLanguage() {
        let source = self.source(id: "com.example.Unknown")

        XCTAssertEqual(
            KeyboardInputSourceLocaleResolver.localeIdentifier(
                for: source,
                fallbackLocaleIdentifier: "pt_BR"
            ),
            "pt-BR"
        )
    }

    func testCompatibleModelsFilterByDetectedLanguageAndProvidedAvailability() {
        let source = self.source(
            id: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",
            languages: ["ja"]
        )
        let availableModels: [SettingsStore.SpeechModel] = [
            .appleSpeech,
            .appleSpeechAnalyzer,
            .cohereTranscribeSixBit,
            .nemotronOffline,
            .parakeetTDT,
            .parakeetTDTv2,
            .parakeetRealtime,
            .whisperSmall,
        ]

        let compatibleModels = RecordingSpeechConfigurationResolver.compatibleModels(
            for: source,
            availableModels: availableModels,
            fallbackLocaleIdentifier: "en-US"
        )

        XCTAssertEqual(
            Set(compatibleModels.map(\SettingsStore.SpeechModel.rawValue)),
            Set([
                SettingsStore.SpeechModel.appleSpeech.rawValue,
                SettingsStore.SpeechModel.appleSpeechAnalyzer.rawValue,
                SettingsStore.SpeechModel.cohereTranscribeSixBit.rawValue,
                SettingsStore.SpeechModel.nemotronOffline.rawValue,
                SettingsStore.SpeechModel.whisperSmall.rawValue,
            ])
        )
    }

    func testTraditionalChineseDoesNotOfferSimplifiedOnlyNemotronBinding() {
        let source = self.source(id: "com.apple.inputmethod.TCIM.Pinyin", languages: ["zh-Hant"])
        let availableModels: [SettingsStore.SpeechModel] = [
            .cohereTranscribeSixBit,
            .nemotronStreaming,
            .whisperSmall,
        ]

        let compatibleModels = RecordingSpeechConfigurationResolver.compatibleModels(
            for: source,
            availableModels: availableModels,
            fallbackLocaleIdentifier: "en-US"
        )

        XCTAssertEqual(compatibleModels, [.cohereTranscribeSixBit, .whisperSmall])
    }

    func testWhisperUsesEngineLanguageAliasesForLocaleCodes() {
        let cases: [(localeIdentifier: String, engineLanguageCode: String)] = [
            ("nb-NO", "no"),
            ("fil-PH", "tl"),
            ("jv-ID", "jw"),
        ]

        for item in cases {
            XCTAssertEqual(
                RecordingSpeechConfigurationResolver.languageBinding(
                    for: .whisperSmall,
                    localeIdentifier: item.localeIdentifier
                ),
                .whisper(languageCode: item.engineLanguageCode),
                item.localeIdentifier
            )
        }
    }

    func testAppleAnalyzerReadinessDefersExactSystemCheckToRecordingStart() {
        for isInstalled in [true, false] {
            XCTAssertEqual(
                VoiceEngineSettingsView.inputSourceModelReadinessLabel(
                    model: .appleSpeechAnalyzer,
                    usesGlobalFallback: false,
                    isInstalled: isInstalled
                ),
                "Assigned • System availability checked at recording start"
            )
        }
    }

    func testCloudReadinessUsesCredentialStateInsteadOfLocalArtifactLabels() {
        XCTAssertEqual(
            VoiceEngineSettingsView.inputSourceModelReadinessLabel(
                model: .sonioxV5,
                usesGlobalFallback: false,
                isInstalled: true,
                sonioxCredentialState: .apiKeyRequired
            ),
            "Assigned • API Key Required"
        )
        XCTAssertEqual(
            VoiceEngineSettingsView.inputSourceModelReadinessLabel(
                model: .sonioxV5,
                usesGlobalFallback: true,
                isInstalled: true,
                sonioxCredentialState: .configured
            ),
            "Global default • Configured"
        )
    }

    func testUnverifiedSonioxAssignmentRoutesToSetupWithoutMutatingAssignment() {
        XCTAssertTrue(
            VoiceEngineSettingsViewModel.shouldRouteSonioxAssignmentToSetup(
                model: .sonioxV5,
                credentialState: .apiKeyRequired
            )
        )
        XCTAssertFalse(
            VoiceEngineSettingsViewModel.shouldRouteSonioxAssignmentToSetup(
                model: .sonioxV5,
                credentialState: .configured
            )
        )
        XCTAssertFalse(
            VoiceEngineSettingsViewModel.shouldRouteSonioxAssignmentToSetup(
                model: .appleSpeech,
                credentialState: .apiKeyRequired
            )
        )
    }

    func testOtherModelReadinessStillReflectsInstallation() {
        XCTAssertEqual(
            VoiceEngineSettingsView.inputSourceModelReadinessLabel(
                model: .whisperSmall,
                usesGlobalFallback: false,
                isInstalled: true
            ),
            "Assigned • Ready"
        )
        XCTAssertEqual(
            VoiceEngineSettingsView.inputSourceModelReadinessLabel(
                model: .whisperSmall,
                usesGlobalFallback: true,
                isInstalled: false
            ),
            "Global default • Download required"
        )
    }

    func testAssignedAvailableModelResolvesWithDetectedLocaleAndMatchingBinding() throws {
        let source = self.source(
            id: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",
            languages: ["ja"]
        )
        let fallback = try XCTUnwrap(RecordingSpeechConfiguration(
            inputSourceID: nil,
            localeIdentifier: "en-US",
            model: .appleSpeech,
            languageBinding: .appleSpeech(localeIdentifier: "en-US")
        ))

        let resolved = RecordingSpeechConfigurationResolver.resolve(
            inputSource: source,
            assignedModel: .whisperSmall,
            globalFallback: fallback,
            sonioxLanguageMode: .currentInputSourceOnly,
            sonioxRegion: .global,
            availableModels: [.appleSpeech, .whisperSmall],
            fallbackLocaleIdentifier: "en-US"
        )

        XCTAssertEqual(resolved.inputSourceID, source.id)
        XCTAssertEqual(resolved.localeIdentifier, "ja-JP")
        XCTAssertEqual(resolved.model, .whisperSmall)
        XCTAssertEqual(resolved.languageBinding, .whisper(languageCode: "ja"))
    }

    func testAssignedSonioxSnapshotsJapaneseIMEAndRegion() throws {
        let source = self.source(
            id: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",
            languages: ["ja"]
        )
        let fallback = try self.sonioxFallback(mode: .automatic, region: .global)

        let resolved = RecordingSpeechConfigurationResolver.resolve(
            inputSource: source,
            assignedModel: .sonioxV5,
            globalFallback: fallback,
            sonioxLanguageMode: .currentInputSourceOnly,
            sonioxRegion: .japan,
            availableModels: self.sonioxAvailableModels,
            fallbackLocaleIdentifier: "en-US"
        )

        XCTAssertEqual(resolved.inputSourceID, source.id)
        XCTAssertEqual(resolved.localeIdentifier, "ja-JP")
        XCTAssertEqual(resolved.model, .sonioxV5)
        XCTAssertEqual(
            resolved.languageBinding,
            .soniox(.init(languageCode: "ja", isStrict: true, region: .japan))
        )
    }

    func testGlobalSonioxWithoutAssignmentReDerivesBindingFromSampledIME() throws {
        let fallback = try self.sonioxFallback(mode: .automatic, region: .global)
        let cases: [(KeyboardInputSourceSnapshot, String)] = [
            (self.source(
                id: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",
                languages: ["ja"]
            ), "ja"),
            (self.source(id: "com.apple.keylayout.US", languages: ["en"]), "en"),
        ]

        for (source, expectedCode) in cases {
            let resolved = RecordingSpeechConfigurationResolver.resolve(
                inputSource: source,
                assignedModel: nil,
                globalFallback: fallback,
                sonioxLanguageMode: .currentInputSourceOnly,
                sonioxRegion: .global,
                availableModels: self.sonioxAvailableModels,
                fallbackLocaleIdentifier: "fr-FR"
            )

            XCTAssertEqual(resolved.inputSourceID, source.id)
            XCTAssertEqual(
                resolved.languageBinding,
                .soniox(.init(languageCode: expectedCode, isStrict: true, region: .global))
            )
        }
    }

    func testUnsupportedSonioxLocaleUsesAutomaticNonStrictBinding() throws {
        let source = self.source(id: "com.example.Unsupported", languages: ["eo"])
        let fallback = try self.sonioxFallback(mode: .automatic, region: .global)

        let resolved = RecordingSpeechConfigurationResolver.resolve(
            inputSource: source,
            assignedModel: .sonioxV5,
            globalFallback: fallback,
            sonioxLanguageMode: .currentInputSourceOnly,
            sonioxRegion: .japan,
            availableModels: self.sonioxAvailableModels,
            fallbackLocaleIdentifier: "eo"
        )

        XCTAssertEqual(
            resolved.languageBinding,
            .soniox(.init(languageCode: nil, isStrict: false, region: .japan))
        )
    }

    func testResolvedSonioxConfigurationIsImmutableAcrossLaterSnapshots() throws {
        let fallback = try self.sonioxFallback(mode: .automatic, region: .global)
        let japanese = self.source(
            id: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",
            languages: ["ja"]
        )
        let first = RecordingSpeechConfigurationResolver.resolve(
            inputSource: japanese,
            assignedModel: .sonioxV5,
            globalFallback: fallback,
            sonioxLanguageMode: .currentInputSourceOnly,
            sonioxRegion: .japan,
            availableModels: self.sonioxAvailableModels,
            fallbackLocaleIdentifier: "en-US"
        )

        _ = RecordingSpeechConfigurationResolver.resolve(
            inputSource: self.source(id: "com.apple.keylayout.US", languages: ["en"]),
            assignedModel: .sonioxV5,
            globalFallback: fallback,
            sonioxLanguageMode: .automatic,
            sonioxRegion: .global,
            availableModels: self.sonioxAvailableModels,
            fallbackLocaleIdentifier: "en-US"
        )

        XCTAssertEqual(first.localeIdentifier, "ja-JP")
        XCTAssertEqual(
            first.languageBinding,
            .soniox(.init(languageCode: "ja", isStrict: true, region: .japan))
        )
    }

    func testGlobalFallbackSnapshotsWhisperLanguageWithoutMutatingSettings() throws {
        let configuration = try XCTUnwrap(
            RecordingSpeechConfigurationResolver.globalFallbackConfiguration(
                model: .whisperSmall,
                selectedLanguageID: "ja",
                appleLocaleIdentifier: "en-US",
                cohereLanguage: .english,
                nemotronLanguage: .english,
                sonioxLanguageMode: .currentInputSourceOnly,
                sonioxRegion: .global
            )
        )

        XCTAssertEqual(configuration.localeIdentifier, "ja-JP")
        XCTAssertEqual(configuration.model, .whisperSmall)
        XCTAssertEqual(configuration.languageBinding, .whisper(languageCode: "ja"))
    }

    func testGlobalFallbackUsesProviderSpecificLanguageBindings() throws {
        let apple = try XCTUnwrap(
            RecordingSpeechConfigurationResolver.globalFallbackConfiguration(
                model: .appleSpeech,
                selectedLanguageID: "en",
                appleLocaleIdentifier: "fr-CA",
                cohereLanguage: .english,
                nemotronLanguage: .english,
                sonioxLanguageMode: .currentInputSourceOnly,
                sonioxRegion: .global
            )
        )
        let cohere = try XCTUnwrap(
            RecordingSpeechConfigurationResolver.globalFallbackConfiguration(
                model: .cohereTranscribeSixBit,
                selectedLanguageID: "es",
                appleLocaleIdentifier: "en-US",
                cohereLanguage: .spanish,
                nemotronLanguage: .english,
                sonioxLanguageMode: .currentInputSourceOnly,
                sonioxRegion: .global
            )
        )

        XCTAssertEqual(apple.languageBinding, .appleSpeech(localeIdentifier: "fr-CA"))
        XCTAssertEqual(cohere.languageBinding, .cohere(.spanish))
        XCTAssertEqual(cohere.localeIdentifier, "es-ES")
    }

    func testGlobalFallbackRejectsUnavailableQwenRoute() {
        XCTAssertNil(
            RecordingSpeechConfigurationResolver.globalFallbackConfiguration(
                model: .qwen3Asr,
                selectedLanguageID: "en",
                appleLocaleIdentifier: "en-US",
                cohereLanguage: .english,
                nemotronLanguage: .english,
                sonioxLanguageMode: .currentInputSourceOnly,
                sonioxRegion: .global
            )
        )
    }

    func testMissingAssignmentPreservesWholeGlobalLanguageAndModelRoute() throws {
        let source = self.source(
            id: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",
            languages: ["ja"]
        )
        let fallback = try XCTUnwrap(RecordingSpeechConfiguration(
            inputSourceID: nil,
            localeIdentifier: "en-US",
            model: .appleSpeech,
            languageBinding: .appleSpeech(localeIdentifier: "en-US")
        ))

        let resolved = RecordingSpeechConfigurationResolver.resolve(
            inputSource: source,
            assignedModel: nil,
            globalFallback: fallback,
            sonioxLanguageMode: .currentInputSourceOnly,
            sonioxRegion: .global,
            availableModels: [.appleSpeech, .whisperSmall],
            fallbackLocaleIdentifier: "en-US"
        )

        XCTAssertEqual(resolved.inputSourceID, source.id)
        XCTAssertEqual(resolved.localeIdentifier, "en-US")
        XCTAssertEqual(resolved.model, .appleSpeech)
        XCTAssertEqual(resolved.languageBinding, .appleSpeech(localeIdentifier: "en-US"))
    }

    func testUnavailableOrIncompatibleAssignmentFallsBackWithoutRemovingIt() throws {
        let source = self.source(
            id: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",
            languages: ["ja"]
        )
        let fallback = try XCTUnwrap(RecordingSpeechConfiguration(
            inputSourceID: nil,
            localeIdentifier: "en-US",
            model: .appleSpeech,
            languageBinding: .appleSpeech(localeIdentifier: "en-US")
        ))

        let unavailable = RecordingSpeechConfigurationResolver.resolve(
            inputSource: source,
            assignedModel: .whisperSmall,
            globalFallback: fallback,
            sonioxLanguageMode: .currentInputSourceOnly,
            sonioxRegion: .global,
            availableModels: [.appleSpeech],
            fallbackLocaleIdentifier: "en-US"
        )
        let incompatible = RecordingSpeechConfigurationResolver.resolve(
            inputSource: source,
            assignedModel: .parakeetRealtime,
            globalFallback: fallback,
            sonioxLanguageMode: .currentInputSourceOnly,
            sonioxRegion: .global,
            availableModels: [.appleSpeech, .parakeetRealtime],
            fallbackLocaleIdentifier: "en-US"
        )

        XCTAssertEqual(unavailable.model, .appleSpeech)
        XCTAssertEqual(unavailable.localeIdentifier, "en-US")
        XCTAssertEqual(incompatible.model, .appleSpeech)
        XCTAssertEqual(incompatible.localeIdentifier, "en-US")
    }

    func testResolvedConfigurationDoesNotChangeWhenNextInputSourceSnapshotChanges() throws {
        let fallback = try XCTUnwrap(RecordingSpeechConfiguration(
            inputSourceID: nil,
            localeIdentifier: "en-US",
            model: .appleSpeech,
            languageBinding: .appleSpeech(localeIdentifier: "en-US")
        ))
        let japaneseSource = self.source(
            id: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",
            languages: ["ja"]
        )
        let englishSource = self.source(id: "com.apple.keylayout.US", languages: ["en"])

        let first = RecordingSpeechConfigurationResolver.resolve(
            inputSource: japaneseSource,
            assignedModel: .whisperSmall,
            globalFallback: fallback,
            sonioxLanguageMode: .currentInputSourceOnly,
            sonioxRegion: .global,
            availableModels: [.appleSpeech, .whisperSmall],
            fallbackLocaleIdentifier: "en-US"
        )
        _ = RecordingSpeechConfigurationResolver.resolve(
            inputSource: englishSource,
            assignedModel: .appleSpeech,
            globalFallback: fallback,
            sonioxLanguageMode: .currentInputSourceOnly,
            sonioxRegion: .global,
            availableModels: [.appleSpeech, .whisperSmall],
            fallbackLocaleIdentifier: "en-US"
        )

        XCTAssertEqual(first.inputSourceID, japaneseSource.id)
        XCTAssertEqual(first.localeIdentifier, "ja-JP")
        XCTAssertEqual(first.model, .whisperSmall)
        XCTAssertEqual(first.languageBinding, .whisper(languageCode: "ja"))
    }

    private func source(
        id: String,
        name: String = "Test Input Source",
        languages: [String] = []
    ) -> KeyboardInputSourceSnapshot {
        KeyboardInputSourceSnapshot(id: id, localizedName: name, languages: languages)
    }

    private func sonioxFallback(
        mode: SettingsStore.SonioxLanguageMode,
        region: SettingsStore.SonioxRegion
    ) throws -> RecordingSpeechConfiguration {
        try XCTUnwrap(RecordingSpeechConfigurationResolver.globalFallbackConfiguration(
            model: .sonioxV5,
            selectedLanguageID: "en",
            appleLocaleIdentifier: "en-US",
            cohereLanguage: .english,
            nemotronLanguage: .english,
            sonioxLanguageMode: mode,
            sonioxRegion: region
        ))
    }
}

final class DictationTranscriptComposerTests: XCTestCase {
    func testCombinesEnglishSegmentsWithASpace() {
        XCTAssertEqual(
            DictationTranscriptComposer.combine(["hello", "world"]),
            "hello world"
        )
    }

    func testKeepsJapaneseSegmentsInlineWithoutInventingSpaces() {
        XCTAssertEqual(
            DictationTranscriptComposer.combine(["こんにちは", "世界"]),
            "こんにちは世界"
        )
    }

    func testDoesNotAddSpaceBeforePunctuation() {
        XCTAssertEqual(
            DictationTranscriptComposer.combine(["hello", ", world"]),
            "hello, world"
        )
    }

    func testIgnoresEmptySegmentsWithoutDroppingExistingText() {
        XCTAssertEqual(
            DictationTranscriptComposer.combine(["first", "   ", "second"]),
            "first second"
        )
    }
}

@MainActor
final class LiveInputSourceSwitchTests: XCTestCase {
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

#if arch(arm64)
    func testRapidInputSourceSwitchesKeepTheLatestPendingConfiguration() throws {
        let english = try XCTUnwrap(RecordingSpeechConfiguration(
            inputSourceID: "com.apple.keylayout.ABC",
            localeIdentifier: "en-US",
            model: .parakeetTDTv2,
            languageBinding: .automatic
        ))
        let japanese = try XCTUnwrap(RecordingSpeechConfiguration(
            inputSourceID: "com.google.inputmethod.Japanese.base",
            localeIdentifier: "ja-JP",
            model: .sonioxV5,
            languageBinding: .soniox(.init(
                languageCode: "ja",
                isStrict: false,
                region: .global
            ))
        ))
        var pending = RecordingSpeechConfigurationSwitchQueue()
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
        XCTAssertNil(pending.take())
    }
#endif

#if arch(arm64)
    func testFluidAudioDeclaresMinimumFinalAudioLengthForLiveSwitchBoundaries() {
        let provider = FluidAudioProvider()

        XCTAssertEqual(provider.minimumFinalAudioSampleCount, 16_000)
    }
#endif

    func testSwitchKeepsCommittedTextAndAppendsTheNextSegment() async throws {
        let english = try XCTUnwrap(RecordingSpeechConfiguration(
            inputSourceID: "com.apple.keylayout.US",
            localeIdentifier: "en-US",
            model: .whisperBase,
            languageBinding: .whisper(languageCode: "en")
        ))
        let japanese = try XCTUnwrap(RecordingSpeechConfiguration(
            inputSourceID: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",
            localeIdentifier: "ja-JP",
            model: .whisperBase,
            languageBinding: .whisper(languageCode: "ja")
        ))
        let asr = ASRService(localProviderFactory: { configuration in
            SegmentTranscriptProvider(text: configuration.localeIdentifier == "ja-JP" ? "世界" : "hello")
        })
        let sessionID = RecordingSessionID()
        let oldProvider = SegmentTranscriptProvider(
            text: "hello",
            minimumFinalAudioSampleCount: 16_000
        )
        _ = asr.installTestingRecordingSession(
            sessionID: sessionID,
            configuration: english,
            provider: oldProvider,
            isRunning: true,
            capturedSamples: Array(repeating: 0.1, count: 8_000)
        )

        let didSwitch = await asr.switchRecordingSpeechConfiguration(
            sessionID: sessionID,
            speechConfiguration: japanese
        )
        XCTAssertTrue(didSwitch)
        XCTAssertEqual(oldProvider.lastFinalSampleCount, 16_000)
        XCTAssertEqual(asr.partialTranscription, "hello")

        asr.appendTestingCapturedSamples(Array(repeating: 0.1, count: 16_000))
        let finalTranscript = await asr.stop(sessionID: sessionID)
        XCTAssertEqual(finalTranscript, "hello 世界")
    }
}

@MainActor
final class RecordingSpeechSessionSelectionTests: XCTestCase {
    func testSelectionKeepsConfigurationSnapshotAndBlocksReplacement() throws {
        let firstID = try self.sessionID("11111111-1111-1111-1111-111111111111")
        let secondID = try self.sessionID("22222222-2222-2222-2222-222222222222")
        let firstConfiguration = try XCTUnwrap(RecordingSpeechConfiguration(
            inputSourceID: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",
            localeIdentifier: "ja-JP",
            model: .whisperSmall,
            languageBinding: .whisper(languageCode: "ja")
        ))
        let replacementConfiguration = try XCTUnwrap(RecordingSpeechConfiguration(
            inputSourceID: "com.apple.keylayout.US",
            localeIdentifier: "en-US",
            model: .appleSpeech,
            languageBinding: .appleSpeech(localeIdentifier: "en-US")
        ))
        var state = RecordingSpeechSessionSelectionState()

        XCTAssertTrue(state.begin(sessionID: firstID, configuration: firstConfiguration))
        XCTAssertFalse(state.begin(sessionID: secondID, configuration: replacementConfiguration))

        XCTAssertEqual(state.selection(matching: firstID)?.configuration, firstConfiguration)
        XCTAssertEqual(state.selection(matching: firstID)?.providerKey, "whisper-small:whisper-ja")
    }

    func testStaleSessionIDCannotReadOrClearActiveSelection() throws {
        let activeID = try self.sessionID("33333333-3333-3333-3333-333333333333")
        let staleID = try self.sessionID("44444444-4444-4444-4444-444444444444")
        let configuration = try XCTUnwrap(RecordingSpeechConfiguration(
            inputSourceID: "com.apple.keylayout.US",
            localeIdentifier: "en-US",
            model: .cohereTranscribeSixBit,
            languageBinding: .cohere(.english)
        ))
        var state = RecordingSpeechSessionSelectionState()
        XCTAssertTrue(state.begin(sessionID: activeID, configuration: configuration))

        XCTAssertNil(state.selection(matching: staleID))
        XCTAssertFalse(state.clear(matching: staleID))
        XCTAssertEqual(state.selection(matching: activeID)?.configuration, configuration)

        XCTAssertTrue(state.clear(matching: activeID))
        XCTAssertNil(state.activeSelection)
    }

    func testProviderKeyIncludesLanguageBinding() throws {
        let english = try XCTUnwrap(RecordingSpeechConfiguration(
            inputSourceID: nil,
            localeIdentifier: "en-US",
            model: .whisperBase,
            languageBinding: .whisper(languageCode: "en")
        ))
        let japanese = try XCTUnwrap(RecordingSpeechConfiguration(
            inputSourceID: nil,
            localeIdentifier: "ja-JP",
            model: .whisperBase,
            languageBinding: .whisper(languageCode: "ja")
        ))

        let englishSelection = try XCTUnwrap(RecordingSpeechSessionSelection(
            sessionID: RecordingSessionID(),
            configuration: english
        ))
        let japaneseSelection = try XCTUnwrap(RecordingSpeechSessionSelection(
            sessionID: RecordingSessionID(),
            configuration: japanese
        ))

        XCTAssertNotEqual(englishSelection.providerKey, japaneseSelection.providerKey)
    }

    func testSonioxBindingIDIncludesOnlyImmutableScope() throws {
        let binding = VoiceEngineLanguageRoute.LanguageBinding.soniox(.init(
            languageCode: "ja",
            isStrict: true,
            region: .japan
        ))
        let configuration = try XCTUnwrap(RecordingSpeechConfiguration(
            inputSourceID: nil,
            localeIdentifier: "ja-JP",
            model: .sonioxV5,
            languageBinding: binding
        ))
        let selection = try XCTUnwrap(RecordingSpeechSessionSelection(
            sessionID: RecordingSessionID(),
            configuration: configuration
        ))

        XCTAssertEqual(binding.id, "soniox-japan-ja-strict")
        XCTAssertEqual(selection.providerKey, "soniox-v5:soniox-japan-ja-strict")
        XCTAssertFalse(binding.id.localizedCaseInsensitiveContains("key"))
    }

    func testQwenSelectionIsRejectedWhileRuntimeIsUnavailable() throws {
        let configuration = try XCTUnwrap(RecordingSpeechConfiguration(
            inputSourceID: nil,
            localeIdentifier: "en-US",
            model: .qwen3Asr,
            languageBinding: .automatic
        ))

        XCTAssertNil(RecordingSpeechSessionSelection(
            sessionID: RecordingSessionID(),
            configuration: configuration
        ))
    }

    func testRecordingPresentationContextClearsTargetIconAndIMEBadge() {
        let state = NotchContentState.shared
        state.targetAppIcon = NSImage(size: NSSize(width: 16, height: 16))
        state.recordingInputSourceBadge = KeyboardInputSourceBadge(
            sourceID: "com.google.inputmethod.Japanese.base",
            localeIdentifier: "ja-JP",
            nativeIcon: nil,
            fallbackText: "🇯🇵"
        )
        state.recordingActivationStyle = .pushToTalk

        state.clearRecordingPresentationContext()

        XCTAssertNil(state.targetAppIcon)
        XCTAssertNil(state.recordingInputSourceBadge)
        XCTAssertNil(state.recordingActivationStyle)
    }

    private func sessionID(
        _ rawValue: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> RecordingSessionID {
        try RecordingSessionID(
            rawValue: XCTUnwrap(UUID(uuidString: rawValue), file: file, line: line)
        )
    }
}

@MainActor
private final class SegmentTranscriptProvider: TranscriptionProvider {
    let name = "Segment transcript test provider"
    let isAvailable = true
    private(set) var isReady = true
    private let text: String
    let minimumFinalAudioSampleCount: Int
    private(set) var lastFinalSampleCount: Int?

    init(text: String, minimumFinalAudioSampleCount: Int = 0) {
        self.text = text
        self.minimumFinalAudioSampleCount = minimumFinalAudioSampleCount
    }

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
        _ = progressHandler
        self.isReady = true
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        _ = samples
        return ASRTranscriptionResult(text: self.text)
    }

    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        self.lastFinalSampleCount = samples.count
        return ASRTranscriptionResult(text: self.text)
    }
}

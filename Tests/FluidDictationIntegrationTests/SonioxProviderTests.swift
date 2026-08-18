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

    func testFinalizationArbiterGivesTheFirstTerminalEventPrecedence() {
        var finishedFirst = SonioxFinalizationArbiter()
        XCTAssertTrue(finishedFirst.claimFinished())
        XCTAssertFalse(finishedFirst.claimTimeout())

        var timeoutFirst = SonioxFinalizationArbiter()
        XCTAssertTrue(timeoutFirst.claimTimeout())
        XCTAssertFalse(timeoutFirst.claimFinished())
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

    func testPrepareValidatesSnapshotKeyWithoutOpeningSocket() async throws {
        let transport = ControllableSonioxTransport()
        let factory = SonioxTestTransportFactory([transport])
        let provider = self.makeProvider(apiKey: "  snapshot-key  ", factory: factory)

        try await provider.prepare(progressHandler: nil)

        XCTAssertTrue(provider.isReady)
        XCTAssertEqual(factory.makeCount, 0)
        XCTAssertTrue(provider.modelsExistOnDisk())
        XCTAssertFalse(provider.allowsTranscriptLogging)
        XCTAssertFalse(provider.shouldClearCacheAfterCancellation)

        let missingKeyProvider = self.makeProvider(apiKey: " \n ", factory: factory)
        await self.assertThrows {
            try await missingKeyProvider.prepare(progressHandler: nil)
        }
        XCTAssertFalse(missingKeyProvider.isReady)
        XCTAssertEqual(factory.makeCount, 0)
    }

    func testFirstPreviewSendsConfigurationBeforeAudio() async throws {
        let transport = ControllableSonioxTransport()
        let factory = SonioxTestTransportFactory([transport])
        let provider = self.makeProvider(factory: factory)
        try await provider.prepare(progressHandler: nil)

        _ = try await provider.transcribeStreaming([0.25, -0.5])

        let frames = transport.sentFrames
        XCTAssertEqual(frames.count, 2)
        let configuration = try self.configurationObject(from: frames[0])
        XCTAssertEqual(configuration["api_key"] as? String, "test-key")
        XCTAssertEqual(configuration["model"] as? String, SonioxProvider.modelID)
        XCTAssertEqual(configuration["language_hints"] as? [String], ["ja"])
        XCTAssertEqual(configuration["language_hints_strict"] as? Bool, true)
        XCTAssertEqual(self.sampleCount(in: frames[1]), 2)
        XCTAssertEqual(factory.requestedURLs, [SettingsStore.SonioxRegion.japan.webSocketURL])
    }

    func testConcurrentCallDuringConfigurationFailsWithoutSendingAudio() async throws {
        let transport = ControllableSonioxTransport(suspendedSendIndices: [0])
        let provider = self.makeProvider(factory: SonioxTestTransportFactory([transport]))
        try await provider.prepare(progressHandler: nil)
        let firstPreview = Task { try await provider.transcribeStreaming([1, 2]) }
        await self.waitUntil { transport.sentFrames.count == 1 }

        do {
            _ = try await provider.transcribeStreaming([1, 2, 3])
            XCTFail("Expected an overlapping provider operation to fail")
        } catch let error as SonioxError {
            XCTAssertEqual(error.category, .configuration)
            XCTAssertEqual(error.diagnosticType, "operation_in_progress")
        }
        XCTAssertEqual(transport.sentFrames.count, 1)

        transport.resumeSend(at: 0)
        _ = try await firstPreview.value

        XCTAssertEqual(transport.sentFrames.compactMap(\.binaryData).flatMap(self.decodeSamples), [1, 2])
        XCTAssertEqual(transport.closeDispositions, [])
    }

    func testCancelledOverlappingCallCannotCancelActiveOperation() async throws {
        let transport = ControllableSonioxTransport(suspendedSendIndices: [0])
        let provider = self.makeProvider(factory: SonioxTestTransportFactory([transport]))
        try await provider.prepare(progressHandler: nil)
        let activePreview = Task { try await provider.transcribeStreaming([1, 2]) }
        await self.waitUntil { transport.sentFrames.count == 1 }

        let cancelledOverlap = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await provider.transcribeStreaming([1, 2, 3])
        }
        await self.assertTaskThrows(cancelledOverlap)
        XCTAssertEqual(transport.closeDispositions, [])
        XCTAssertEqual(transport.sentFrames.count, 1)

        transport.resumeSend(at: 0)
        _ = try await activePreview.value

        XCTAssertEqual(transport.sentFrames.compactMap(\.binaryData).flatMap(self.decodeSamples), [1, 2])
        XCTAssertEqual(transport.closeDispositions, [])
    }

    func testCumulativePrefixesSendOnlyNewSuffixIn960SampleFrames() async throws {
        let transport = ControllableSonioxTransport()
        let provider = self.makeProvider(factory: SonioxTestTransportFactory([transport]))
        try await provider.prepare(progressHandler: nil)
        let allSamples = (0..<2000).map(Float.init)

        _ = try await provider.transcribeStreaming(Array(allSamples.prefix(1000)))
        _ = try await provider.transcribeStreaming(allSamples)

        let audioFrames = transport.sentFrames.compactMap(\.binaryData)
        XCTAssertEqual(audioFrames.map { $0.count / MemoryLayout<Float>.size }, [960, 40, 960, 40])
        XCTAssertEqual(audioFrames.flatMap(self.decodeSamples), allSamples)
    }

    func testEqualPrefixReturnsSnapshotWithoutAnotherBinaryFrame() async throws {
        let transport = ControllableSonioxTransport()
        let provider = self.makeProvider(factory: SonioxTestTransportFactory([transport]))
        try await provider.prepare(progressHandler: nil)
        let samples: [Float] = [0.1, 0.2]
        _ = try await provider.transcribeStreaming(samples)
        let frameCount = transport.sentFrames.count

        let snapshot = try await provider.transcribeStreaming(samples)

        XCTAssertEqual(snapshot.text, "")
        XCTAssertEqual(transport.sentFrames.count, frameCount)
    }

    func testShrinkingPrefixFailsWithoutReconnecting() async throws {
        let transport = ControllableSonioxTransport()
        let factory = SonioxTestTransportFactory([transport])
        let provider = self.makeProvider(factory: factory)
        try await provider.prepare(progressHandler: nil)
        _ = try await provider.transcribeStreaming([0, 1, 2])

        await self.assertThrows {
            try await provider.transcribeStreaming([0, 1])
        }
        await self.assertThrows {
            try await provider.transcribeStreaming([0, 1, 2, 3])
        }

        XCTAssertEqual(factory.makeCount, 1)
        XCTAssertEqual(transport.closeDispositions, [.cancelled])
    }

    func testPreviewReturnsLatestSnapshotWithoutWaitingForNextResponse() async throws {
        let transport = ControllableSonioxTransport()
        let provider = self.makeProvider(factory: SonioxTestTransportFactory([transport]))
        try await provider.prepare(progressHandler: nil)
        _ = try await provider.transcribeStreaming([0])
        transport.enqueue(.text(self.serverMessage(tokens: [("draft", false)], finished: false)))

        var snapshot = try await provider.transcribeStreaming([0])
        for _ in 0..<1000 where snapshot.text != "draft" {
            await Task.yield()
            snapshot = try await provider.transcribeStreaming([0])
        }
        XCTAssertEqual(snapshot.text, "draft")

        let next = try await provider.transcribeStreaming([0, 1])
        XCTAssertEqual(next.text, "draft")
        XCTAssertEqual(transport.pendingReceiveCount, 1)
    }

    func testFinalizationWithoutPriorPreviewConnectsAndConfiguresBeforeAudio() async throws {
        let transport = ControllableSonioxTransport()
        let provider = self.makeProvider(factory: SonioxTestTransportFactory([transport]))
        try await provider.prepare(progressHandler: nil)
        let finalTask = Task { try await provider.transcribeFinal([]) }

        await self.waitUntil { transport.sentFrames.count >= 6 }
        let frames = transport.sentFrames
        _ = try self.configurationObject(from: frames[0])
        XCTAssertEqual(frames[1...4].compactMap(\.binaryData).map { $0.count / 4 }, [960, 960, 960, 320])
        XCTAssertEqual(frames[5], .text("{\"type\":\"finalize\"}"))
        transport.enqueue(.text(self.serverMessage(tokens: [("<fin>", true)], finished: false)))
        await self.waitUntil { transport.sentFrames.count >= 7 }
        transport.enqueue(.text(self.serverMessage(tokens: [], finished: true)))

        _ = try await finalTask.value
    }

    func testFinalizationWireOrderAndFinalOnlyResult() async throws {
        let transport = ControllableSonioxTransport()
        let provider = self.makeProvider(factory: SonioxTestTransportFactory([transport]))
        try await provider.prepare(progressHandler: nil)
        _ = try await provider.transcribeStreaming([1, 2])
        transport.enqueue(.text(self.serverMessage(tokens: [("old-draft", false)], finished: false)))
        let finalTask = Task { try await provider.transcribeFinal([1, 2, 3, 4, 5]) }

        await self.waitUntil { transport.sentFrames.count >= 8 }
        let finalFrames = Array(transport.sentFrames.dropFirst(2))
        XCTAssertEqual(finalFrames.compactMap(\.binaryData).prefix(5).map { $0.count / 4 }, [3, 960, 960, 960, 320])
        XCTAssertEqual(try self.decodeSamples(XCTUnwrap(finalFrames[0].binaryData)), [3, 4, 5])
        XCTAssertTrue(finalFrames[1...4].compactMap(\.binaryData).flatMap(self.decodeSamples).allSatisfy { $0 == 0 })
        XCTAssertEqual(finalFrames[5], .text("{\"type\":\"finalize\"}"))

        transport.enqueue(.text(self.serverMessage(tokens: [("answer", true), ("ignored", false), ("<fin>", true)], finished: false)))
        await self.waitUntil { transport.sentFrames.count >= 9 }
        XCTAssertEqual(transport.sentFrames[8], .binary(Data()))
        transport.enqueue(.text(self.serverMessage(tokens: [("!", true)], finished: true)))

        let result = try await finalTask.value
        XCTAssertEqual(result.text, "answer!")
        XCTAssertEqual(transport.closeDispositions, [.normal])
        XCTAssertEqual(transport.pendingReceiveCount, 0)
    }

    func testFinalizationSendsEndOfAudioWithoutWaitingForFin() async throws {
        let transport = ControllableSonioxTransport()
        let provider = self.makeProvider(factory: SonioxTestTransportFactory([transport]))
        try await provider.prepare(progressHandler: nil)

        let finalTask = Task { try await provider.transcribeFinal([]) }
        await self.waitUntil { transport.sentFrames.count >= 7 }

        XCTAssertEqual(transport.sentFrames[5], .text("{\"type\":\"finalize\"}"))
        XCTAssertEqual(transport.sentFrames[6], .binary(Data()))
        transport.enqueue(.text(self.serverMessage(tokens: [("answer", true)], finished: true)))

        let result = try await finalTask.value
        XCTAssertEqual(result.text, "answer")
        XCTAssertEqual(transport.closeDispositions, [.normal])
    }

    func testTimeoutStartsOnlyAfterFinalizeSendCompletes() async throws {
        let transport = ControllableSonioxTransport(suspendedSendIndices: [5])
        let sleeper = ManualSonioxSleeper()
        let provider = self.makeProvider(factory: SonioxTestTransportFactory([transport]), sleeper: sleeper)
        try await provider.prepare(progressHandler: nil)
        let finalTask = Task { try await provider.transcribeFinal([]) }

        await self.waitUntil { transport.sentFrames.count >= 6 }
        XCTAssertEqual(sleeper.callCount, 0)
        transport.resumeSend(at: 5)
        await self.waitUntil { sleeper.callCount == 1 }
        transport.enqueue(.text(self.serverMessage(tokens: [("<fin>", true)], finished: false)))
        await self.waitUntil { transport.sentFrames.count >= 7 }
        transport.enqueue(.text(self.serverMessage(tokens: [], finished: true)))

        _ = try await finalTask.value
    }

    func testDiscardWhileWaitingForFinCancelsReceiveAndAllWaiters() async throws {
        let transport = ControllableSonioxTransport()
        let provider = self.makeProvider(factory: SonioxTestTransportFactory([transport]))
        try await provider.prepare(progressHandler: nil)
        let finalTask = Task { try await provider.transcribeFinal([]) }
        await self.waitUntil { transport.sentFrames.count >= 6 && transport.pendingReceiveCount == 1 }

        await provider.resetAfterCancellation()
        await self.assertTaskThrows(finalTask)

        XCTAssertEqual(transport.closeDispositions, [.cancelled])
        XCTAssertEqual(transport.pendingReceiveCount, 0)
    }

    func testParentTaskCancellationClosesTransportBeforeAwaitingProviderCleanup() async throws {
        let transport = ControllableSonioxTransport()
        let provider = self.makeProvider(factory: SonioxTestTransportFactory([transport]))
        try await provider.prepare(progressHandler: nil)
        let finalTask = Task { try await provider.transcribeFinal([]) }
        await self.waitUntil { transport.sentFrames.count >= 6 && transport.pendingReceiveCount == 1 }

        finalTask.cancel()
        XCTAssertEqual(transport.closeDispositions, [.cancelled])
        await self.assertTaskThrows(finalTask)
    }

    func testCancellationDuringConfigurationSendDoesNotSendAudioAfterClose() async throws {
        let transport = ControllableSonioxTransport(
            suspendedSendIndices: [0],
            cancellationResistantSendIndices: [0]
        )
        let provider = self.makeProvider(factory: SonioxTestTransportFactory([transport]))
        try await provider.prepare(progressHandler: nil)
        let previewTask = Task { try await provider.transcribeStreaming([1]) }
        await self.waitUntil { transport.sentFrames.count == 1 }

        previewTask.cancel()
        XCTAssertEqual(transport.closeDispositions, [.cancelled])
        transport.resumeSend(at: 0)
        await self.assertTaskThrows(previewTask)

        XCTAssertEqual(transport.sentFrames.count, 1)
    }

    func testFinishedResponseBeforeEndOfAudioSendCompletesFinalization() async throws {
        let transport = ControllableSonioxTransport()
        let provider = self.makeProvider(factory: SonioxTestTransportFactory([transport]))
        try await provider.prepare(progressHandler: nil)
        let finalTask = Task { try await provider.transcribeFinal([]) }
        await self.waitUntil { transport.sentFrames.count >= 6 }

        transport.enqueue(.text(self.serverMessage(tokens: [("premature", true), ("<fin>", true)], finished: true)))
        let result = try await finalTask.value

        XCTAssertEqual(result.text, "premature")
        XCTAssertEqual(transport.sentFrames.count, 7)
        XCTAssertEqual(transport.closeDispositions, [.normal])
    }

    func testFinishedWhileEmptyFrameSendIsSuspendedWaitsForSuccessfulSend() async throws {
        let transport = ControllableSonioxTransport(
            suspendedSendIndices: [6],
            cancellationResistantSendIndices: [6]
        )
        let provider = self.makeProvider(factory: SonioxTestTransportFactory([transport]))
        try await provider.prepare(progressHandler: nil)
        let finalTask = Task { try await provider.transcribeFinal([]) }
        await self.waitUntil { transport.sentFrames.count >= 6 }
        transport.enqueue(.text(self.serverMessage(tokens: [("<fin>", true)], finished: false)))
        await self.waitUntil { transport.sentFrames.count >= 7 }

        transport.enqueue(.text(self.serverMessage(tokens: [("answer", true)], finished: true)))
        await self.waitUntil { transport.pendingReceiveCount == 0 }
        XCTAssertEqual(transport.closeDispositions, [])
        transport.resumeSend(at: 6)
        let result = try await finalTask.value

        XCTAssertEqual(result.text, "answer")
        XCTAssertEqual(transport.closeDispositions, [.normal])
    }

    func testFinishedImmediatelyAfterEmptyFrameSendCompletesFinalizesNormally() async throws {
        let transport = ControllableSonioxTransport(suspendedSendIndices: [6])
        let provider = self.makeProvider(factory: SonioxTestTransportFactory([transport]))
        try await provider.prepare(progressHandler: nil)
        let finalTask = Task { try await provider.transcribeFinal([]) }
        await self.waitUntil { transport.sentFrames.count >= 6 }
        transport.enqueue(.text(self.serverMessage(tokens: [("answer", true), ("<fin>", true)], finished: false)))
        // Latch the resume so the test remains deterministic even if the
        // provider appends the empty frame just before installing the fake
        // transport's continuation.
        transport.resumeSend(at: 6)
        transport.enqueue(.text(self.serverMessage(tokens: [], finished: true)))
        let result = try await finalTask.value

        XCTAssertEqual(result.text, "answer")
        XCTAssertEqual(transport.closeDispositions, [.normal])
    }

    func testCancelledPrepareDoesNotLatchCancellationIntoLaterRecording() async throws {
        let transport = ControllableSonioxTransport()
        let provider = self.makeProvider(factory: SonioxTestTransportFactory([transport]))
        try await provider.prepare(progressHandler: nil)
        XCTAssertTrue(provider.isReady)

        let cancelledPrepare = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await provider.prepare(progressHandler: nil)
        }
        await self.assertVoidTaskThrows(cancelledPrepare)
        XCTAssertFalse(provider.isReady)

        try await provider.prepare(progressHandler: nil)
        XCTAssertTrue(provider.isReady)
        _ = try await provider.transcribeStreaming([1])

        XCTAssertEqual(transport.closeDispositions, [])
    }

    func testTransportFailureAtStartConfigurationAudioFinalizeAndEmptyFrameIsTerminal() async throws {
        let startTransport = ControllableSonioxTransport(startError: SonioxTestError.injected)
        let startFactory = SonioxTestTransportFactory([startTransport])
        let startProvider = self.makeProvider(factory: startFactory)
        try await startProvider.prepare(progressHandler: nil)
        do {
            _ = try await startProvider.transcribeStreaming([1])
            XCTFail("Expected transport start failure")
        } catch {
            let sonioxError = try XCTUnwrap(error as? SonioxError)
            XCTAssertEqual(sonioxError.category, .temporaryService)
            XCTAssertEqual(sonioxError.diagnosticType, "unknown_error_type")
        }
        await self.assertThrows { try await startProvider.transcribeStreaming([1, 2]) }
        XCTAssertEqual(startFactory.makeCount, 1)
        XCTAssertEqual(startTransport.closeDispositions, [.cancelled])

        let configurationTransport = ControllableSonioxTransport(failingSendIndices: [0])
        let configurationProvider = self.makeProvider(factory: SonioxTestTransportFactory([configurationTransport]))
        try await configurationProvider.prepare(progressHandler: nil)
        await self.assertThrows { try await configurationProvider.transcribeStreaming([1]) }
        XCTAssertEqual(configurationTransport.closeDispositions, [.cancelled])

        let audioTransport = ControllableSonioxTransport(failingSendIndices: [1])
        let audioProvider = self.makeProvider(factory: SonioxTestTransportFactory([audioTransport]))
        try await audioProvider.prepare(progressHandler: nil)
        await self.assertThrows { try await audioProvider.transcribeStreaming([1]) }
        XCTAssertEqual(audioTransport.closeDispositions, [.cancelled])

        let finalizeTransport = ControllableSonioxTransport(failingSendIndices: [5])
        let finalizeProvider = self.makeProvider(factory: SonioxTestTransportFactory([finalizeTransport]))
        try await finalizeProvider.prepare(progressHandler: nil)
        await self.assertThrows { try await finalizeProvider.transcribeFinal([]) }
        XCTAssertEqual(finalizeTransport.closeDispositions, [.cancelled])

        let emptyTransport = ControllableSonioxTransport(failingSendIndices: [6])
        let emptyProvider = self.makeProvider(factory: SonioxTestTransportFactory([emptyTransport]))
        try await emptyProvider.prepare(progressHandler: nil)
        let emptyTask = Task { try await emptyProvider.transcribeFinal([]) }
        await self.waitUntil { emptyTransport.sentFrames.count >= 6 }
        emptyTransport.enqueue(.text(self.serverMessage(tokens: [("<fin>", true)], finished: false)))
        await self.assertTaskThrows(emptyTask)
        XCTAssertEqual(emptyTransport.closeDispositions, [.cancelled])
    }

    func testMalformedTextAndUnexpectedBinaryResponseFailAndClearState() async throws {
        for response in [SonioxWebSocketFrame.text("not-json"), .binary(Data([1]))] {
            let transport = ControllableSonioxTransport()
            let provider = self.makeProvider(factory: SonioxTestTransportFactory([transport]))
            try await provider.prepare(progressHandler: nil)
            _ = try await provider.transcribeStreaming([1])

            transport.enqueue(response)
            await self.waitForProviderFailure(provider, samples: [1])

            XCTAssertEqual(transport.closeDispositions, [.cancelled])
            XCTAssertEqual(transport.pendingReceiveCount, 0)
        }
    }

    func testCloseBeforeFinAndCloseAfterFinBeforeFinishedUnblockWithoutOutput() async throws {
        let beforeFinTransport = ControllableSonioxTransport()
        let beforeFinProvider = self.makeProvider(factory: SonioxTestTransportFactory([beforeFinTransport]))
        try await beforeFinProvider.prepare(progressHandler: nil)
        let beforeFinTask = Task { try await beforeFinProvider.transcribeFinal([]) }
        await self.waitUntil { beforeFinTransport.sentFrames.count >= 6 }
        beforeFinTransport.enqueueFailure(SonioxTestError.remoteClosed)
        await self.assertTaskThrows(beforeFinTask)
        XCTAssertEqual(beforeFinTransport.closeDispositions, [.cancelled])

        let afterFinTransport = ControllableSonioxTransport()
        let afterFinProvider = self.makeProvider(factory: SonioxTestTransportFactory([afterFinTransport]))
        try await afterFinProvider.prepare(progressHandler: nil)
        let afterFinTask = Task { try await afterFinProvider.transcribeFinal([]) }
        await self.waitUntil { afterFinTransport.sentFrames.count >= 6 }
        afterFinTransport.enqueue(.text(self.serverMessage(tokens: [("unpublished", false), ("<fin>", true)], finished: false)))
        await self.waitUntil { afterFinTransport.sentFrames.count >= 7 }
        afterFinTransport.enqueueFailure(SonioxTestError.remoteClosed)
        await self.assertTaskThrows(afterFinTask)
        XCTAssertEqual(afterFinTransport.closeDispositions, [.cancelled])
    }

    func testLateFinAndFinishedAfterTimeoutCannotPublishOutput() async throws {
        let transport = ControllableSonioxTransport()
        let sleeper = ManualSonioxSleeper()
        let provider = self.makeProvider(factory: SonioxTestTransportFactory([transport]), sleeper: sleeper)
        try await provider.prepare(progressHandler: nil)
        let finalTask = Task { try await provider.transcribeFinal([]) }
        await self.waitUntil { sleeper.callCount == 1 }

        sleeper.fireAll()
        await self.assertTaskThrows(finalTask)
        transport.enqueue(.text(self.serverMessage(tokens: [("late", true), ("<fin>", true)], finished: true)))
        await Task.yield()
        await self.assertThrows { try await provider.transcribeStreaming([]) }

        XCTAssertEqual(transport.closeDispositions, [.cancelled])
        XCTAssertFalse(transport.closeDispositions.contains(.normal))
    }

    func testResetAfterCancellationIsIdempotent() async throws {
        let transport = ControllableSonioxTransport()
        let provider = self.makeProvider(factory: SonioxTestTransportFactory([transport]))
        try await provider.prepare(progressHandler: nil)
        let finalTask = Task { try await provider.transcribeFinal([]) }
        await self.waitUntil { transport.sentFrames.count >= 6 }

        await provider.resetAfterCancellation()
        await provider.resetAfterCancellation()
        await self.assertTaskThrows(finalTask)

        XCTAssertEqual(transport.closeDispositions, [.cancelled])
    }

    func testFreshProviderStartsAtSampleZeroWithNewTransport() async throws {
        let firstTransport = ControllableSonioxTransport()
        let firstProvider = self.makeProvider(factory: SonioxTestTransportFactory([firstTransport]))
        try await firstProvider.prepare(progressHandler: nil)
        _ = try await firstProvider.transcribeStreaming(Array(repeating: 1, count: 100))
        await firstProvider.resetAfterCancellation()

        let secondTransport = ControllableSonioxTransport()
        let secondProvider = self.makeProvider(factory: SonioxTestTransportFactory([secondTransport]))
        try await secondProvider.prepare(progressHandler: nil)
        _ = try await secondProvider.transcribeStreaming([7, 8])

        XCTAssertEqual(secondTransport.sentFrames.compactMap(\.binaryData).map { $0.count / 4 }, [2])
        XCTAssertEqual(try self.decodeSamples(XCTUnwrap(secondTransport.sentFrames.last?.binaryData)), [7, 8])
    }

    func testProviderContractDefaultsAndWhisperMinimumOverride() {
        XCTAssertEqual(DefaultContractProvider().minimumFinalAudioSampleCount, 0)
        XCTAssertTrue(DefaultContractProvider().allowsTranscriptLogging)
        XCTAssertEqual(WhisperProvider().minimumFinalAudioSampleCount, 16_000)
    }

    func testSonioxReceivesActualShortPCMWithoutOneSecondAppPadding() async throws {
        let captured = [Float(0.25), -0.5]
        let transport = ControllableSonioxTransport()
        let provider = self.makeProvider(factory: SonioxTestTransportFactory([transport]))
        try await provider.prepare(progressHandler: nil)

        let finalTask = Task { try await provider.transcribeFinal(captured) }
        await self.waitUntil { transport.sentFrames.count >= 7 }

        let binaryFrames = transport.sentFrames.compactMap(\.binaryData)
        XCTAssertEqual(binaryFrames.first.map { $0.count / MemoryLayout<Float>.size }, captured.count)
        XCTAssertEqual(
            try self.decodeSamples(XCTUnwrap(binaryFrames.first)),
            captured
        )
        XCTAssertEqual(provider.minimumFinalAudioSampleCount, 0)

        transport.enqueue(.text(self.serverMessage(tokens: [("<fin>", true)], finished: false)))
        await self.waitUntil { transport.sentFrames.count >= 8 }
        transport.enqueue(.text(self.serverMessage(tokens: [], finished: true)))
        _ = try await finalTask.value
        XCTAssertEqual(transport.closeDispositions, [.normal])
    }

    func testWhisperStillReceivesAtLeastOneSecondOfFinalAudio() {
        let captured = [Float(0.25), -0.5]
        let whisper = WhisperProvider()

        XCTAssertEqual(
            ASRService.finalAudioSamples(
                captured,
                minimumSampleCount: whisper.minimumFinalAudioSampleCount
            ).count,
            16_000
        )
        XCTAssertEqual(
            Array(ASRService.finalAudioSamples(
                captured,
                minimumSampleCount: whisper.minimumFinalAudioSampleCount
            ).prefix(2)),
            captured
        )
    }

    func testStaleStreamingOwnerCannotMatchReplacementSession() {
        let staleSession = RecordingSessionID()
        let currentSession = RecordingSessionID()
        let staleOwner = StreamingTaskOwner(
            sessionID: staleSession,
            providerKey: "soniox-v5",
            token: UUID()
        )
        let currentOwner = StreamingTaskOwner(
            sessionID: currentSession,
            providerKey: "soniox-v5",
            token: UUID()
        )

        XCTAssertTrue(ASRService.isStreamingOwnerMatch(
            currentOwner,
            activeOwner: currentOwner,
            activeSessionID: currentSession,
            activeProviderKey: "soniox-v5"
        ))
        XCTAssertFalse(ASRService.isStreamingOwnerMatch(
            staleOwner,
            activeOwner: currentOwner,
            activeSessionID: currentSession,
            activeProviderKey: "soniox-v5"
        ))
        XCTAssertFalse(ASRService.isStreamingOwnerMatch(
            staleOwner,
            activeOwner: staleOwner,
            activeSessionID: currentSession,
            activeProviderKey: "soniox-v5"
        ))
        XCTAssertFalse(ASRService.isStreamingOwnerMatch(
            currentOwner,
            activeOwner: currentOwner,
            activeSessionID: staleSession,
            activeProviderKey: "soniox-v5"
        ))
        XCTAssertFalse(ASRService.isStreamingOwnerMatch(
            currentOwner,
            activeOwner: currentOwner,
            activeSessionID: currentSession,
            activeProviderKey: "different-provider"
        ))
        XCTAssertTrue(ASRService.isStreamingCancellationOwnerMatch(
            currentOwner,
            sessionID: currentSession,
            providerKey: "soniox-v5",
            activeOwner: currentOwner,
            activeSessionID: currentSession,
            activeProviderKey: "soniox-v5"
        ))
        XCTAssertFalse(ASRService.isStreamingCancellationOwnerMatch(
            staleOwner,
            sessionID: currentSession,
            providerKey: "soniox-v5",
            activeOwner: currentOwner,
            activeSessionID: currentSession,
            activeProviderKey: "soniox-v5"
        ))
        XCTAssertFalse(ASRService.isStreamingCancellationOwnerMatch(
            currentOwner,
            sessionID: currentSession,
            providerKey: "different-provider",
            activeOwner: currentOwner,
            activeSessionID: currentSession,
            activeProviderKey: "soniox-v5"
        ))
    }

    func testGracefulQuiesceDoesNotCancelInFlightPreviewSocket() async throws {
        let transport = ControllableSonioxTransport(suspendedSendIndices: [0])
        let provider = self.makeProvider(factory: SonioxTestTransportFactory([transport]))
        try await provider.prepare(progressHandler: nil)

        let previewTask = Task { try await provider.transcribeStreaming([1, 2]) }
        await self.waitUntil { transport.sentFrames.count == 1 }

        XCTAssertEqual(transport.closeDispositions, [])
        transport.resumeSend(at: 0)
        _ = try await previewTask.value

        XCTAssertEqual(transport.closeDispositions, [])
        await provider.resetAfterCancellation()
    }

    func testDiscardStillHardCancelsInFlightPreviewAndReceive() async throws {
        let transport = ControllableSonioxTransport()
        let provider = self.makeProvider(factory: SonioxTestTransportFactory([transport]))
        try await provider.prepare(progressHandler: nil)

        let finalTask = Task { try await provider.transcribeFinal([]) }
        await self.waitUntil { transport.sentFrames.count >= 6 && transport.pendingReceiveCount == 1 }

        await provider.resetAfterCancellation()
        await self.assertTaskThrows(finalTask)

        XCTAssertEqual(transport.closeDispositions, [.cancelled])
        XCTAssertEqual(transport.pendingReceiveCount, 0)
    }

    func testNoAudioAndShortSilenceResetOpenedProviderWithoutFinalizing() async throws {
        XCTAssertFalse(ASRService.assessShortAudioSilence([]).isEligible)
        XCTAssertTrue(ASRService.assessShortAudioSilence([Float](repeating: 0, count: 320)).shouldSkipTranscription)

        let transport = ControllableSonioxTransport()
        let provider = self.makeProvider(factory: SonioxTestTransportFactory([transport]))
        try await provider.prepare(progressHandler: nil)
        _ = try await provider.transcribeStreaming([0, 0])

        await provider.resetAfterCancellation()

        XCTAssertEqual(transport.closeDispositions, [.cancelled])
        XCTAssertFalse(transport.sentFrames.contains { frame in
            guard case let .text(text) = frame else { return false }
            return text == "{\"type\":\"finalize\"}"
        })
    }

    func testSonioxFinalErrorDoesNotPromotePartialToFinalOutput() async throws {
        let transport = ControllableSonioxTransport()
        let provider = self.makeProvider(factory: SonioxTestTransportFactory([transport]))
        try await provider.prepare(progressHandler: nil)
        _ = try await provider.transcribeStreaming([1])

        transport.enqueue(.text(self.serverMessage(tokens: [("partial", false)], finished: false)))
        var preview = try await provider.transcribeStreaming([1])
        for _ in 0..<1000 where preview.text != "partial" {
            await Task.yield()
            preview = try await provider.transcribeStreaming([1])
        }
        XCTAssertEqual(preview.text, "partial")

        let finalTask = Task { try await provider.transcribeFinal([1]) }
        await self.waitUntil { transport.sentFrames.contains { frame in
            guard case let .text(text) = frame else { return false }
            return text == "{\"type\":\"finalize\"}"
        } }
        transport.enqueueFailure(SonioxTestError.remoteClosed)

        await self.assertTaskThrows(finalTask)
        XCTAssertEqual(transport.closeDispositions, [.cancelled])
    }

    func testTerminationClosesOpenSonioxSocketAndUnblocksReceive() async throws {
        let transport = ControllableSonioxTransport()
        let provider = self.makeProvider(factory: SonioxTestTransportFactory([transport]))
        try await provider.prepare(progressHandler: nil)

        let finalTask = Task { try await provider.transcribeFinal([]) }
        await self.waitUntil { transport.sentFrames.count >= 6 && transport.pendingReceiveCount == 1 }

        await provider.resetAfterCancellation()
        await self.assertTaskThrows(finalTask)

        XCTAssertEqual(transport.closeDispositions, [.cancelled])
        XCTAssertEqual(transport.pendingReceiveCount, 0)
    }

    func testSonioxTranscriptAndConfigurationNeverReachDebugMessages() async throws {
        let transport = ControllableSonioxTransport()
        let provider = self.makeProvider(factory: SonioxTestTransportFactory([transport]))
        let existingLogIDs = Set(DebugLogger.shared.logs.map(\.id))
        try await provider.prepare(progressHandler: nil)
        _ = try await provider.transcribeStreaming([1, 2])

        XCTAssertFalse(provider.allowsTranscriptLogging)
        let newLogEntries = DebugLogger.shared.logs.filter { !existingLogIDs.contains($0.id) }
        XCTAssertFalse(newLogEntries.contains { entry in
            entry.message.contains("partial") || entry.message.contains("configuration")
        })

        await provider.resetAfterCancellation()
    }

    func testOwnedFailureShowsSanitizedRequestIDButNeverDiagnosticSlugOrServerProse() {
        let serverSlug = "server said: raw response body"
        let error = SonioxErrorMapper.error(errorType: serverSlug, requestID: "request_42")
        let copy = SonioxErrorMapper.userFacingCopy(for: error.category)

        XCTAssertEqual(error.requestID, "request_42")
        XCTAssertFalse(copy.title.contains(serverSlug))
        XCTAssertFalse(copy.message.contains(serverSlug))
        XCTAssertFalse(copy.message.contains(error.diagnosticType))
        XCTAssertEqual(copy, SonioxErrorMapper.userFacingCopy(for: .temporaryService))
    }

    func testRequestCancellationRejectsLateOwnerRunBeforeActorDrain() async {
        let executor = TranscriptionExecutor()
        let ownerID = UUID()
        let operationExecutions = Task7Counter()

        executor.requestCancellation(ownerID: ownerID)

        do {
            let _: String = try await executor.run(ownerID: ownerID) {
                operationExecutions.increment()
                return "stale"
            }
            XCTFail("Expected a synchronously cancelled owner to reject late work")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }

        XCTAssertEqual(operationExecutions.value, 0)
    }

    func testCancelledStreamingCompletionMonitorIgnoresTerminalResult() async {
        let provider = Task7StreamingFailureProvider(blocksStreaming: true)
        let service = ASRService()
        let sessionID = RecordingSessionID()
        var failureCount = 0
        service.setRecordingFailureHandler { _ in failureCount += 1 }
        _ = service.installTestingRecordingSession(
            sessionID: sessionID,
            configuration: self.sonioxConfiguration(),
            provider: provider,
            isRunning: true,
            capturedSamples: [Float](repeating: 0.25, count: 1600)
        )

        service.startTestingStreamingTranscription(sessionID: sessionID)
        await self.waitUntil { provider.streamingOperationEntered }
        let monitorTask = service.cancelTestingStreamingCompletionMonitor()
        provider.releaseStreaming()
        _ = await monitorTask?.result

        XCTAssertEqual(failureCount, 0)
        XCTAssertTrue(service.hasActiveRecordingSession)
        XCTAssertEqual(provider.resetCount, 0)

        let didDiscard = await service.stopWithoutTranscription(sessionID: sessionID)
        XCTAssertTrue(didDiscard)
    }

    func testNormalStopOverlappingTerminalFailureWaitsForTeardownAndDeliversFailureOnce() async {
        let captureGate = Task7AsyncGate()
        let provider = Task7StreamingFailureProvider(blocksStreaming: false)
        let sessionID = RecordingSessionID()
        let failureExpectation = expectation(description: "owned streaming failure delivered")
        var failureCount = 0
        let service = ASRService(
            lifecycleHooks: ASRServiceLifecycleHooks(
                cancelAudioRouteRecoveryAndWait: {},
                stopActiveAudioCapture: { _, _ in await captureGate.wait() },
                retireAudioEngineAndWait: { _ in }
            )
        )
        service.setRecordingFailureHandler { failure in
            failureCount += 1
            XCTAssertEqual(failure.sessionID, sessionID)
            XCTAssertEqual(provider.resetCount, 1)
            XCTAssertFalse(service.hasActiveRecordingSession)
            XCTAssertFalse(service.isRunning)
            XCTAssertEqual(service.partialTranscription, "")
            failureExpectation.fulfill()
        }
        _ = service.installTestingRecordingSession(
            sessionID: sessionID,
            configuration: self.sonioxConfiguration(),
            provider: provider,
            isRunning: true,
            capturedSamples: [Float](repeating: 0.25, count: 1600)
        )

        service.startTestingStreamingTranscription(sessionID: sessionID)
        await self.waitUntil { provider.streamingOperationEntered && captureGate.isWaiting }

        let normalStopTask = Task { await service.stop(sessionID: sessionID) }
        for _ in 0..<100 {
            await Task.yield()
        }
        XCTAssertTrue(service.hasActiveRecordingSession)
        XCTAssertEqual(provider.resetCount, 0)

        captureGate.open()
        _ = await normalStopTask.value
        await fulfillment(of: [failureExpectation], timeout: 1)
        XCTAssertEqual(failureCount, 1)
        XCTAssertFalse(service.hasActiveRecordingSession)
    }

    func testStreamingTerminalErrorStopsCaptureBeforeDismissingAndClearsMatchingSelection() async {
        let events = Task7EventLog()
        let provider = Task7StreamingFailureProvider(blocksStreaming: false)
        let sessionID = RecordingSessionID()
        let failureExpectation = expectation(description: "owned streaming failure delivered")
        var failureCount = 0
        let service = ASRService(
            lifecycleHooks: ASRServiceLifecycleHooks(
                cancelAudioRouteRecoveryAndWait: { events.append("route") },
                stopActiveAudioCapture: { _, _ in events.append("capture") },
                retireAudioEngineAndWait: { _ in events.append("retire") }
            )
        )
        service.setRecordingFailureHandler { failure in
            failureCount += 1
            XCTAssertEqual(failure.sessionID, sessionID)
            XCTAssertEqual(provider.resetCount, 1)
            XCTAssertFalse(service.hasActiveRecordingSession)
            XCTAssertFalse(service.isRunning)
            XCTAssertEqual(service.partialTranscription, "")
            XCTAssertNil(service.consumeLastCompletedAudioSnapshot(for: sessionID))
            XCTAssertEqual(service.finalText, "")
            events.append("failure")
            failureExpectation.fulfill()
        }
        _ = service.installTestingRecordingSession(
            sessionID: sessionID,
            configuration: self.sonioxConfiguration(),
            provider: provider,
            isRunning: true,
            capturedSamples: [Float](repeating: 0.25, count: 1600)
        )

        service.startTestingStreamingTranscription(sessionID: sessionID)
        await self.waitUntil { provider.streamingOperationEntered }
        await fulfillment(of: [failureExpectation])

        XCTAssertEqual(failureCount, 1)
        XCTAssertEqual(events.values, ["route", "capture", "retire", "failure"])
        XCTAssertFalse(service.hasActiveRecordingSession)
        XCTAssertNil(service.consumeLastCompletedAudioSnapshot(for: sessionID))
    }

    func testStopDoesNotMutateReplacementSessionAfterCaptureTeardownAwaits() async {
        let captureGate = Task7AsyncGate()
        let hooks = ASRServiceLifecycleHooks(
            cancelAudioRouteRecoveryAndWait: {},
            stopActiveAudioCapture: { _, _ in await captureGate.wait() },
            retireAudioEngineAndWait: { _ in }
        )
        let service = ASRService(lifecycleHooks: hooks)
        let configuration = self.appleSpeechConfiguration()
        let providerA = Task7LifecycleProvider(response: ASRTranscriptionResult(text: "old"))
        let providerB = Task7LifecycleProvider(response: ASRTranscriptionResult(text: "new"))
        let sessionA = RecordingSessionID()
        let sessionB = RecordingSessionID()
        _ = service.installTestingRecordingSession(
            sessionID: sessionA,
            configuration: configuration,
            provider: providerA,
            isRunning: true,
            capturedSamples: [0.25]
        )

        let settledTickBeforeStop = service.audioCaptureStateSettledTick
        let stopTask = Task { await service.stop(sessionID: sessionA) }
        await self.waitUntil { captureGate.isWaiting }
        _ = service.replaceTestingRecordingSession(
            sessionID: sessionB,
            configuration: configuration,
            provider: providerB,
            isRunning: true,
            capturedSamples: [0.5]
        )
        captureGate.open()

        _ = await stopTask.value
        XCTAssertTrue(service.hasActiveRecordingSession)
        XCTAssertTrue(service.isRunningOrStarting)
        XCTAssertEqual(service.activeRecordingSpeechModel, configuration.model)
        XCTAssertEqual(service.audioCaptureStateSettledTick, settledTickBeforeStop)
        XCTAssertEqual(providerB.resetCount, 0)
    }

    func testDiscardDoesNotRetireReplacementSessionAfterCaptureTeardownAwaits() async {
        let captureGate = Task7AsyncGate()
        let retireCalls = Task7Counter()
        let hooks = ASRServiceLifecycleHooks(
            cancelAudioRouteRecoveryAndWait: {},
            stopActiveAudioCapture: { _, _ in await captureGate.wait() },
            retireAudioEngineAndWait: { _ in retireCalls.increment() }
        )
        let service = ASRService(lifecycleHooks: hooks)
        let configuration = self.appleSpeechConfiguration()
        let providerA = Task7LifecycleProvider()
        let providerB = Task7LifecycleProvider()
        let sessionA = RecordingSessionID()
        let sessionB = RecordingSessionID()
        _ = service.installTestingRecordingSession(
            sessionID: sessionA,
            configuration: configuration,
            provider: providerA,
            isRunning: true
        )

        let discardTask = Task { await service.stopWithoutTranscription(sessionID: sessionA) }
        await self.waitUntil { captureGate.isWaiting }
        _ = service.replaceTestingRecordingSession(
            sessionID: sessionB,
            configuration: configuration,
            provider: providerB,
            isRunning: true
        )
        captureGate.open()

        let didDiscard = await discardTask.value
        XCTAssertFalse(didDiscard)
        XCTAssertEqual(retireCalls.value, 0)
        XCTAssertTrue(service.hasActiveRecordingSession)
        XCTAssertTrue(service.isRunningOrStarting)
        XCTAssertEqual(providerB.resetCount, 0)
    }

    func testTerminationDoesNotMutateReplacementSessionAfterRouteTeardownAwaits() async {
        let routeGate = Task7AsyncGate()
        let hooks = ASRServiceLifecycleHooks(
            cancelAudioRouteRecoveryAndWait: { await routeGate.wait() },
            stopActiveAudioCapture: { _, _ in },
            retireAudioEngineAndWait: { _ in },
            shutdownDirectCapture: { _ in }
        )
        let service = ASRService(lifecycleHooks: hooks)
        let configuration = self.appleSpeechConfiguration()
        let providerA = Task7LifecycleProvider()
        let providerB = Task7LifecycleProvider()
        let sessionA = RecordingSessionID()
        let sessionB = RecordingSessionID()
        _ = service.installTestingRecordingSession(
            sessionID: sessionA,
            configuration: configuration,
            provider: providerA,
            isRunning: true
        )

        let terminationTask = Task { await service.shutdownForTermination() }
        await self.waitUntil { routeGate.isWaiting }
        _ = service.replaceTestingRecordingSession(
            sessionID: sessionB,
            configuration: configuration,
            provider: providerB,
            isRunning: true
        )
        routeGate.open()

        await terminationTask.value
        XCTAssertTrue(service.hasActiveRecordingSession)
        XCTAssertTrue(service.isRunningOrStarting)
        XCTAssertEqual(service.activeRecordingSpeechModel, configuration.model)
        XCTAssertEqual(providerB.resetCount, 0)
    }

    func testDiscardCancelsOwnedProviderBeforeBlockedRouteTeardown() async {
        let routeGate = Task7AsyncGate()
        let hooks = ASRServiceLifecycleHooks(
            cancelAudioRouteRecoveryAndWait: { await routeGate.wait() },
            stopActiveAudioCapture: { _, _ in },
            retireAudioEngineAndWait: { _ in }
        )
        let service = ASRService(lifecycleHooks: hooks)
        let configuration = self.appleSpeechConfiguration()
        let provider = Task7LifecycleProvider()
        let sessionID = RecordingSessionID()
        let owner = service.installTestingRecordingSession(
            sessionID: sessionID,
            configuration: configuration,
            provider: provider,
            isRunning: true
        )
        let transcriptionTask = service.startTestingOwnedTranscription(
            provider: provider,
            sessionID: owner.sessionID
        )
        await self.waitUntil { provider.finalOperationEntered }

        let discardTask = Task { await service.stopWithoutTranscription(sessionID: sessionID) }
        await self.waitUntil { routeGate.isWaiting }
        XCTAssertTrue(provider.cancellationObserved)
        routeGate.open()

        let didDiscard = await discardTask.value
        XCTAssertTrue(didDiscard)
        _ = await transcriptionTask.value
    }

    func testTerminationDoesNotCancelUnownedLocalAPIOperation() async throws {
        let provider = Task7LifecycleProvider()
        let configuration = self.appleSpeechConfiguration()
        let service = ASRService(
            localProviderFactory: { _ in provider },
            lifecycleHooks: ASRServiceLifecycleHooks(
                cancelAudioRouteRecoveryAndWait: {},
                retireAudioEngineAndWait: { _ in },
                shutdownDirectCapture: { _ in }
            )
        )
        let apiTask = Task {
            try await service.transcribeSamplesForAPI([0.25], configuration: configuration)
        }
        await self.waitUntil { provider.finalOperationEntered }

        await service.shutdownForTermination()
        XCTAssertFalse(provider.cancellationObserved)
        provider.completeFinal()
        let result = try await apiTask.value
        XCTAssertEqual(result.text, "completed")
    }

    func testCompletedAudioSnapshotCannotCrossRecordingSessionOwnership() async {
        let settings = SettingsStore.shared
        let previousHistory = settings.saveTranscriptionHistory
        let previousAudioHistory = settings.saveAudioWithTranscriptionHistory
        let previousSkipSilent = settings.skipSilentRecordingsEnabled
        defer {
            settings.saveTranscriptionHistory = previousHistory
            settings.saveAudioWithTranscriptionHistory = previousAudioHistory
            settings.skipSilentRecordingsEnabled = previousSkipSilent
        }
        settings.saveTranscriptionHistory = true
        settings.saveAudioWithTranscriptionHistory = true
        settings.skipSilentRecordingsEnabled = false

        let service = ASRService(
            lifecycleHooks: ASRServiceLifecycleHooks(
                cancelAudioRouteRecoveryAndWait: {},
                stopActiveAudioCapture: { _, _ in },
                retireAudioEngineAndWait: { _ in }
            )
        )
        let configuration = self.appleSpeechConfiguration()
        let sessionA = RecordingSessionID()
        let providerA = Task7LifecycleProvider(
            response: ASRTranscriptionResult(text: "snapshot-source"),
            blocksFinalOperation: false
        )
        _ = service.installTestingRecordingSession(
            sessionID: sessionA,
            configuration: configuration,
            provider: providerA,
            isRunning: true,
            capturedSamples: [0.25]
        )
        let output = await service.stop(sessionID: sessionA)
        XCTAssertEqual(output, "snapshot-source")

        let sessionB = RecordingSessionID()
        let providerB = Task7LifecycleProvider(
            response: ASRTranscriptionResult(text: "discarded"),
            blocksFinalOperation: false
        )
        _ = service.replaceTestingRecordingSession(
            sessionID: sessionB,
            configuration: configuration,
            provider: providerB,
            isRunning: false
        )
        XCTAssertNil(service.consumeLastCompletedAudioSnapshot(for: sessionB))
        let didDiscard = await service.stopWithoutTranscription(sessionID: sessionB)
        XCTAssertTrue(didDiscard)
        XCTAssertNil(service.consumeLastCompletedAudioSnapshot(for: sessionA))
    }

    private func appleSpeechConfiguration() -> RecordingSpeechConfiguration {
        guard let configuration = RecordingSpeechConfiguration(
            inputSourceID: "com.apple.keylayout.US",
            localeIdentifier: "en-US",
            model: .appleSpeech,
            languageBinding: .appleSpeech(localeIdentifier: "en-US")
        ) else {
            preconditionFailure("The test recording configuration must remain valid")
        }
        return configuration
    }

    private func sonioxConfiguration() -> RecordingSpeechConfiguration {
        guard let configuration = RecordingSpeechConfiguration(
            inputSourceID: nil,
            localeIdentifier: "en-US",
            model: .sonioxV5,
            languageBinding: .soniox(.init(languageCode: "en", isStrict: true, region: .global))
        ) else {
            preconditionFailure("The test Soniox configuration must remain valid")
        }
        return configuration
    }

    private func makeProvider(
        apiKey: String = "test-key",
        factory: SonioxTestTransportFactory,
        sleeper: ManualSonioxSleeper = ManualSonioxSleeper()
    ) -> SonioxProvider {
        SonioxProvider(
            apiKey: apiKey,
            binding: SonioxSessionBinding(languageCode: "ja", isStrict: true, region: .japan),
            transportFactory: factory.make,
            sleep: sleeper.sleep,
            finalizationTimeout: .seconds(10)
        )
    }

    private func configurationObject(from frame: SonioxWebSocketFrame) throws -> [String: Any] {
        guard case let .text(text) = frame else {
            XCTFail("Expected configuration text frame")
            throw SonioxTestError.unexpectedFrame
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func sampleCount(in frame: SonioxWebSocketFrame) -> Int? {
        frame.binaryData.map { $0.count / MemoryLayout<Float>.size }
    }

    private func decodeSamples(_ data: Data) -> [Float] {
        stride(from: 0, to: data.count, by: 4).map { offset in
            let bits = data[offset..<offset + 4].enumerated().reduce(UInt32(0)) { partial, byte in
                partial | (UInt32(byte.element) << UInt32(byte.offset * 8))
            }
            return Float(bitPattern: bits)
        }
    }

    private func serverMessage(tokens: [(String, Bool)], finished: Bool) -> String {
        let object: [String: Any] = [
            "tokens": tokens.map { ["text": $0.0, "is_final": $0.1] },
            "finished": finished,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(bytes: data, encoding: .utf8)
        else {
            preconditionFailure("Static test server message must encode")
        }
        return text
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<10_000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Condition was not reached", file: file, line: line)
    }

    private func waitForProviderFailure(_ provider: SonioxProvider, samples: [Float]) async {
        for _ in 0..<10_000 {
            do {
                _ = try await provider.transcribeStreaming(samples)
                await Task.yield()
            } catch {
                return
            }
        }
        XCTFail("Provider did not enter a terminal state")
    }

    private func assertTaskThrows(
        _ task: Task<ASRTranscriptionResult, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("Expected task to throw", file: file, line: line)
        } catch {}
    }

    private func assertVoidTaskThrows(
        _ task: Task<Void, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await task.value
            XCTFail("Expected task to throw", file: file, line: line)
        } catch {}
    }

    private func assertThrows(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> some Any
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected operation to throw", file: file, line: line)
        } catch {}
    }
}

private enum SonioxTestError: Error {
    case injected
    case remoteClosed
    case unexpectedFrame
}

private enum SonioxTestCloseDisposition: Equatable {
    case normal
    case cancelled
}

private extension SonioxWebSocketFrame {
    var binaryData: Data? {
        guard case let .binary(data) = self else { return nil }
        return data
    }
}

private final nonisolated class SonioxTestTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [ControllableSonioxTransport]
    private var urls: [URL] = []

    init(_ transports: [ControllableSonioxTransport]) {
        self.transports = transports
    }

    var makeCount: Int {
        self.lock.withLock { self.urls.count }
    }

    var requestedURLs: [URL] {
        self.lock.withLock { self.urls }
    }

    func make(_ url: URL) -> any SonioxWebSocketTransport {
        self.lock.withLock {
            self.urls.append(url)
            precondition(self.transports.isEmpty == false, "Unexpected extra transport")
            return self.transports.removeFirst()
        }
    }
}

private final nonisolated class ControllableSonioxTransport: SonioxWebSocketTransport, @unchecked Sendable {
    private struct State {
        var frames: [SonioxWebSocketFrame] = []
        var closes: [SonioxTestCloseDisposition] = []
        var receiveEvents: [Result<SonioxWebSocketFrame, Error>] = []
        var receiveContinuation: CheckedContinuation<SonioxWebSocketFrame, Error>?
        var sendContinuations: [Int: CheckedContinuation<Void, Error>] = [:]
        var earlyResumeSendIndices: Set<Int> = []
        var isClosed = false
    }

    private let lock = NSLock()
    private var state = State()
    private let startError: Error?
    private let failingSendIndices: Set<Int>
    private let suspendedSendIndices: Set<Int>
    private let cancellationResistantSendIndices: Set<Int>

    init(
        startError: Error? = nil,
        failingSendIndices: Set<Int> = [],
        suspendedSendIndices: Set<Int> = [],
        cancellationResistantSendIndices: Set<Int> = []
    ) {
        self.startError = startError
        self.failingSendIndices = failingSendIndices
        self.suspendedSendIndices = suspendedSendIndices
        self.cancellationResistantSendIndices = cancellationResistantSendIndices
    }

    var sentFrames: [SonioxWebSocketFrame] {
        self.lock.withLock { self.state.frames }
    }

    var closeDispositions: [SonioxTestCloseDisposition] {
        self.lock.withLock { self.state.closes }
    }

    var pendingReceiveCount: Int {
        self.lock.withLock { self.state.receiveContinuation == nil ? 0 : 1 }
    }

    var pendingSendIndices: Set<Int> {
        self.lock.withLock { Set(self.state.sendContinuations.keys) }
    }

    func start() async throws {
        if let startError {
            throw startError
        }
    }

    func send(_ frame: SonioxWebSocketFrame) async throws {
        let index = self.lock.withLock { () -> Int in
            let index = self.state.frames.count
            self.state.frames.append(frame)
            return index
        }
        if self.suspendedSendIndices.contains(index) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let disposition = self.lock.withLock { () -> (shouldResume: Bool, shouldCancel: Bool) in
                        guard self.state.isClosed == false else { return (false, true) }
                        if self.state.earlyResumeSendIndices.remove(index) != nil {
                            return (true, false)
                        }
                        self.state.sendContinuations[index] = continuation
                        return (false, false)
                    }
                    if disposition.shouldCancel {
                        continuation.resume(throwing: CancellationError())
                    } else if disposition.shouldResume {
                        continuation.resume()
                    }
                }
            } onCancel: {
                if self.cancellationResistantSendIndices.contains(index) == false {
                    self.cancelSend(at: index)
                }
            }
        }
        if self.failingSendIndices.contains(index) {
            throw SonioxTestError.injected
        }
    }

    func receive() async throws -> SonioxWebSocketFrame {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let event = self.lock.withLock { () -> Result<SonioxWebSocketFrame, Error>? in
                    if self.state.receiveEvents.isEmpty == false {
                        return self.state.receiveEvents.removeFirst()
                    }
                    if self.state.isClosed {
                        return .failure(CancellationError())
                    }
                    precondition(self.state.receiveContinuation == nil)
                    self.state.receiveContinuation = continuation
                    return nil
                }
                event?.resume(continuation)
            }
        } onCancel: {
            self.cancelReceive()
        }
    }

    func close(_ disposition: SonioxTransportCloseDisposition) {
        let continuations = self.lock.withLock { () -> (
            CheckedContinuation<SonioxWebSocketFrame, Error>?,
            [CheckedContinuation<Void, Error>]
        ) in
            guard self.state.isClosed == false else { return (nil, []) }
            self.state.isClosed = true
            self.state.closes.append(disposition == .normal ? .normal : .cancelled)
            let receiveContinuation = self.state.receiveContinuation
            self.state.receiveContinuation = nil
            let cancelledSends = self.state.sendContinuations.filter {
                self.cancellationResistantSendIndices.contains($0.key) == false
            }
            self.state.sendContinuations = self.state.sendContinuations.filter {
                self.cancellationResistantSendIndices.contains($0.key)
            }
            return (receiveContinuation, Array(cancelledSends.values))
        }
        continuations.0?.resume(throwing: CancellationError())
        continuations.1.forEach { $0.resume(throwing: CancellationError()) }
    }

    func enqueue(_ frame: SonioxWebSocketFrame) {
        self.enqueue(.success(frame))
    }

    func enqueueFailure(_ error: Error) {
        self.enqueue(.failure(error))
    }

    func resumeSend(at index: Int) {
        let continuation = self.lock.withLock { () -> CheckedContinuation<Void, Error>? in
            if let continuation = self.state.sendContinuations.removeValue(forKey: index) {
                return continuation
            }
            guard self.state.isClosed == false else { return nil }
            self.state.earlyResumeSendIndices.insert(index)
            return nil
        }
        continuation?.resume()
    }

    private func enqueue(_ event: Result<SonioxWebSocketFrame, Error>) {
        let continuation = self.lock.withLock { () -> CheckedContinuation<SonioxWebSocketFrame, Error>? in
            guard self.state.isClosed == false else { return nil }
            guard let continuation = self.state.receiveContinuation else {
                self.state.receiveEvents.append(event)
                return nil
            }
            self.state.receiveContinuation = nil
            return continuation
        }
        continuation.map { event.resume($0) }
    }

    private func cancelReceive() {
        let continuation = self.lock.withLock { () -> CheckedContinuation<SonioxWebSocketFrame, Error>? in
            defer { self.state.receiveContinuation = nil }
            return self.state.receiveContinuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func cancelSend(at index: Int) {
        let continuation = self.lock.withLock { self.state.sendContinuations.removeValue(forKey: index) }
        continuation?.resume(throwing: CancellationError())
    }
}

private extension Result {
    func resume(_ continuation: CheckedContinuation<Success, Error>) {
        switch self {
        case let .success(value): continuation.resume(returning: value)
        case let .failure(error): continuation.resume(throwing: error)
        }
    }
}

private final nonisolated class ManualSonioxSleeper: @unchecked Sendable {
    private final class Operation: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var result: Result<Void, Error>?

        func wait() async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let result = self.lock.withLock { () -> Result<Void, Error>? in
                        guard self.result == nil else { return self.result }
                        self.continuation = continuation
                        return nil
                    }
                    result?.resume(continuation)
                }
            } onCancel: {
                self.complete(.failure(CancellationError()))
            }
        }

        func complete(_ result: Result<Void, Error>) {
            let continuation = self.lock.withLock { () -> CheckedContinuation<Void, Error>? in
                guard self.result == nil else { return nil }
                self.result = result
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation.map { result.resume($0) }
        }
    }

    private let lock = NSLock()
    private var operations: [Operation] = []

    var callCount: Int {
        self.lock.withLock { self.operations.count }
    }

    func sleep(_ duration: Duration) async throws {
        _ = duration
        let operation = Operation()
        self.lock.withLock { self.operations.append(operation) }
        try await operation.wait()
    }

    func fireAll() {
        let operations = self.lock.withLock { self.operations }
        operations.forEach { $0.complete(.success(())) }
    }
}

private final class DefaultContractProvider: TranscriptionProvider {
    let name = "default"
    let isAvailable = true
    let isReady = true

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {}
    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        _ = samples
        return ASRTranscriptionResult(text: "")
    }
}

private final nonisolated class Task7AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    var isWaiting: Bool {
        self.lock.withLock { self.continuation != nil }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = self.lock.withLock { () -> Bool in
                guard self.opened == false else { return true }
                self.continuation = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func open() {
        let continuation = self.lock.withLock { () -> CheckedContinuation<Void, Never>? in
            self.opened = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }
}

private final nonisolated class Task7Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        self.lock.withLock { self.count }
    }

    func increment() {
        self.lock.withLock { self.count += 1 }
    }
}

private final nonisolated class Task7EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    var values: [String] {
        self.lock.withLock { self.events }
    }

    func append(_ event: String) {
        self.lock.withLock { self.events.append(event) }
    }
}

private final nonisolated class Task7CancellationLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var completion: Result<Void, Error>?
    private var entered = false
    private var cancellationWasObserved = false

    var isEntered: Bool {
        self.lock.withLock { self.entered }
    }

    var cancellationObserved: Bool {
        self.lock.withLock { self.cancellationWasObserved }
    }

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result = self.lock.withLock { () -> Result<Void, Error>? in
                    self.entered = true
                    guard self.completion == nil else { return self.completion }
                    self.continuation = continuation
                    return nil
                }
                result?.resume(continuation)
            }
        } onCancel: {
            self.cancel()
        }
    }

    func complete() {
        self.finish(.success(()))
    }

    func cancel() {
        self.lock.withLock { self.cancellationWasObserved = true }
        self.finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Void, Error>) {
        let continuation = self.lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard self.completion == nil else { return nil }
            self.completion = result
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation.map { result.resume($0) }
    }
}

private final nonisolated class Task7LifecycleProvider: TranscriptionProvider, @unchecked Sendable {
    let name = "task-7-lifecycle"
    let isAvailable = true
    let isReady = true
    let response: ASRTranscriptionResult
    private let blocksFinalOperation: Bool
    private let finalLatch = Task7CancellationLatch()
    private let resetCounter = Task7Counter()

    init(
        response: ASRTranscriptionResult = ASRTranscriptionResult(text: "completed"),
        blocksFinalOperation: Bool = true
    ) {
        self.response = response
        self.blocksFinalOperation = blocksFinalOperation
    }

    var finalOperationEntered: Bool {
        self.finalLatch.isEntered
    }

    var cancellationObserved: Bool {
        self.finalLatch.cancellationObserved
    }

    var resetCount: Int {
        self.resetCounter.value
    }

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
        _ = progressHandler
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribeFinal(samples)
    }

    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        _ = samples
        guard self.blocksFinalOperation else { return self.response }
        try await self.finalLatch.wait()
        return self.response
    }

    func completeFinal() {
        self.finalLatch.complete()
    }

    func resetAfterCancellation() async {
        self.resetCounter.increment()
    }
}

private final nonisolated class Task7StreamingFailureProvider: TranscriptionProvider, @unchecked Sendable {
    let name = "task-7-streaming-failure"
    let isAvailable = true
    let isReady = true
    private let blocksStreaming: Bool
    private let streamingGate = Task7AsyncGate()
    private let streamingCounter = Task7Counter()
    private let resetCounter = Task7Counter()
    private let failure = SonioxError(
        category: .temporaryService,
        diagnosticType: "test_terminal_failure",
        requestID: "request_42"
    )

    init(blocksStreaming: Bool) {
        self.blocksStreaming = blocksStreaming
    }

    var streamingOperationEntered: Bool {
        self.streamingCounter.value > 0
    }

    var resetCount: Int {
        self.resetCounter.value
    }

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
        _ = progressHandler
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribeFinal(samples)
    }

    func transcribeStreaming(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        _ = samples
        self.streamingCounter.increment()
        if self.blocksStreaming {
            await self.streamingGate.wait()
        }
        throw self.failure
    }

    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        _ = samples
        return ASRTranscriptionResult(text: "should-not-be-published")
    }

    func resetAfterCancellation() async {
        self.resetCounter.increment()
    }

    func releaseStreaming() {
        self.streamingGate.open()
    }
}

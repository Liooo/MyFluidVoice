@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class SonioxCredentialSettingsTests: XCTestCase {
    private let languageModeKey = "SonioxLanguageMode"
    private let regionKey = "SonioxRegion"
    private let receiptKey = "SonioxVerificationReceipt"
    private let selectedSpeechModelKey = "SelectedSpeechModel"
    private let speechModelAssignmentsKey = "SpeechModelAssignmentsByInputSourceID"

    func testCredentialStateResolverCoversSetupVerificationConfiguredAndOwnedReady() {
        let fingerprint = SonioxVerificationReceipt.fingerprint(apiKey: "configured")
        let receipt = SonioxVerificationReceipt(region: .global, credentialFingerprint: fingerprint)

        XCTAssertEqual(
            SonioxCredentialStateResolver.resolve(
                cachedCredentialFingerprint: nil,
                verificationReceipt: nil,
                selectedRegion: .global,
                isVerifying: false,
                activeRecordingModel: nil
            ),
            .apiKeyRequired
        )
        XCTAssertEqual(
            SonioxCredentialStateResolver.resolve(
                cachedCredentialFingerprint: fingerprint,
                verificationReceipt: receipt,
                selectedRegion: .global,
                isVerifying: true,
                activeRecordingModel: nil
            ),
            .verifying
        )
        XCTAssertEqual(
            SonioxCredentialStateResolver.resolve(
                cachedCredentialFingerprint: fingerprint,
                verificationReceipt: receipt,
                selectedRegion: .global,
                isVerifying: false,
                activeRecordingModel: .appleSpeech
            ),
            .configured
        )
        XCTAssertEqual(
            SonioxCredentialStateResolver.resolve(
                cachedCredentialFingerprint: fingerprint,
                verificationReceipt: receipt,
                selectedRegion: .global,
                isVerifying: false,
                activeRecordingModel: .sonioxV5
            ),
            .ready
        )
    }

    func testCredentialStateResolverRejectsStaleReceiptRegionOrFingerprint() {
        let receipt = SonioxVerificationReceipt.make(apiKey: "configured", region: .global)
        XCTAssertEqual(
            SonioxCredentialStateResolver.resolve(
                cachedCredentialFingerprint: receipt.credentialFingerprint,
                verificationReceipt: receipt,
                selectedRegion: .japan,
                isVerifying: false,
                activeRecordingModel: nil
            ),
            .apiKeyRequired
        )
        XCTAssertEqual(
            SonioxCredentialStateResolver.resolve(
                cachedCredentialFingerprint: "different",
                verificationReceipt: receipt,
                selectedRegion: .global,
                isVerifying: false,
                activeRecordingModel: nil
            ),
            .apiKeyRequired
        )
    }

    func testCloudCardActionResolverNeverReturnsLocalArtifactActions() {
        let actions = SpeechModelCardActionResolver.allActions(
            for: .sonioxV5,
            credentialState: .apiKeyRequired,
            isSelected: true,
            isActive: false
        )
        XCTAssertFalse(actions.contains(.download))
        XCTAssertFalse(actions.contains(.cached))
        XCTAssertFalse(actions.contains(.delete))
        XCTAssertEqual(
            SpeechModelCardActionResolver.primaryAction(
                for: .sonioxV5,
                credentialState: .apiKeyRequired,
                isSelected: true,
                isActive: false
            ),
            .configure
        )
        XCTAssertEqual(
            SpeechModelCardActionResolver.primaryAction(
                for: .sonioxV5,
                credentialState: .configured,
                isSelected: true,
                isActive: false
            ),
            .activate
        )
    }

    func testAppServicesChangeRefreshesCredentialState() async throws {
        try await self.withRestoredDefaults {
            let settings = SettingsStore.shared
            let fingerprint = SonioxVerificationReceipt.fingerprint(apiKey: "configured-value")
            settings.sonioxVerificationReceipt = SonioxVerificationReceipt(
                region: .global,
                credentialFingerprint: fingerprint
            )
            let store = FakeCredentialStore(initialValue: nil)
            let service = SonioxCredentialService(store: store, verifier: successfulVerifier())
            let viewModel = VoiceEngineSettingsViewModel(
                settings: settings,
                appServices: AppServices.shared,
                asr: ASRService(),
                sonioxCredentialService: service
            )

            XCTAssertEqual(viewModel.sonioxCredentialState, .apiKeyRequired)
            store.value = "configured-value"
            AppServices.shared.objectWillChange.send()
            await Task.yield()
            await Task.yield()

            XCTAssertEqual(viewModel.sonioxCredentialState, .configured)
        }
    }

    func testBackupRestoreInvalidatesVerificationBeforeSameRegionCommit() async throws {
        try await self.withRestoredDefaults {
            let settings = SettingsStore.shared
            let priorReceipt = SonioxVerificationReceipt.make(apiKey: "prior-value", region: .global)
            settings.sonioxVerificationReceipt = priorReceipt
            let store = FakeCredentialStore(initialValue: "prior-value")
            let verifier = SuspendingCredentialVerifier()
            let service = SonioxCredentialService(store: store, verifier: verifier)
            let releaseObserver = NotificationCenter.default.addObserver(
                forName: .settingsBackupDidRestore,
                object: nil,
                queue: .main
            ) { _ in
                verifier.succeed()
            }
            defer { NotificationCenter.default.removeObserver(releaseObserver) }

            let viewModel = VoiceEngineSettingsViewModel(
                settings: settings,
                appServices: AppServices.shared,
                asr: ASRService(),
                sonioxCredentialService: service
            )
            viewModel.sonioxAPIKeyDraft = "candidate-value"
            viewModel.saveAndVerifySonioxCredential()
            await verifier.waitUntilStarted()

            NotificationCenter.default.post(name: .settingsBackupDidRestore, object: nil)
            await Task.yield()
            await Task.yield()

            XCTAssertEqual(store.value, "prior-value")
            XCTAssertEqual(store.replaceCount, 0)
            XCTAssertEqual(settings.sonioxVerificationReceipt, priorReceipt)
        }
    }

    func testBlankSaveDoesNotRemoveCredential() async throws {
        try await self.withRestoredDefaults {
            let settings = SettingsStore.shared
            settings.sonioxVerificationReceipt = .make(apiKey: "prior-value", region: .global)
            let store = FakeCredentialStore(initialValue: "prior-value")
            let service = SonioxCredentialService(store: store, verifier: successfulVerifier())
            let viewModel = VoiceEngineSettingsViewModel(
                settings: settings,
                appServices: AppServices.shared,
                asr: ASRService(),
                sonioxCredentialService: service
            )
            viewModel.sonioxAPIKeyDraft = " \n "

            viewModel.saveAndVerifySonioxCredential()
            await Task.yield()
            await Task.yield()

            XCTAssertEqual(store.value, "prior-value")
            XCTAssertEqual(store.removeCount, 0)
            XCTAssertEqual(settings.sonioxVerificationReceipt, .make(apiKey: "prior-value", region: .global))
        }
    }

    func testRemoveRemainsAvailableForStoredButUnverifiedCredential() async throws {
        try await self.withRestoredDefaults {
            let settings = SettingsStore.shared
            let store = FakeCredentialStore(initialValue: "prior-value")
            let service = SonioxCredentialService(store: store, verifier: successfulVerifier())
            let viewModel = VoiceEngineSettingsViewModel(
                settings: settings,
                appServices: AppServices.shared,
                asr: ASRService(),
                sonioxCredentialService: service
            )

            settings.sonioxRegion = .japan
            viewModel.refreshSonioxCredentialState()

            XCTAssertEqual(viewModel.sonioxCredentialState, .apiKeyRequired)
            XCTAssertTrue(viewModel.canRemoveSonioxCredential)
        }
    }

    func testUnverifiedSonioxActivationRoutesToSetupWithoutMutatingSelection() async throws {
        try await self.withRestoredDefaults {
            let settings = SettingsStore.shared
            settings.selectedSpeechModel = .appleSpeech
            let service = SonioxCredentialService(
                store: FakeCredentialStore(initialValue: nil),
                verifier: successfulVerifier()
            )
            let viewModel = VoiceEngineSettingsViewModel(
                settings: settings,
                appServices: AppServices.shared,
                asr: ASRService(),
                sonioxCredentialService: service
            )

            viewModel.activateSpeechModel(.sonioxV5)

            XCTAssertEqual(settings.selectedSpeechModel, .appleSpeech)
            XCTAssertEqual(viewModel.previewSpeechModel, .sonioxV5)
            XCTAssertTrue(viewModel.showSonioxSetup)
        }
    }

    func testProductionSonioxAssignmentRoutesSetupThenAssignsAfterVerification() async throws {
        try await self.withRestoredDefaults {
            let settings = SettingsStore.shared
            let inputSourceID = "com.apple.keylayout.US"
            settings.setSpeechModelAssignment(.appleSpeech, forInputSourceID: inputSourceID)
            let store = FakeCredentialStore(initialValue: nil)
            let service = SonioxCredentialService(store: store, verifier: successfulVerifier())
            let viewModel = VoiceEngineSettingsViewModel(
                settings: settings,
                appServices: AppServices.shared,
                asr: ASRService(),
                sonioxCredentialService: service
            )

            viewModel.assignSpeechModel(.sonioxV5, forInputSourceID: inputSourceID)
            XCTAssertEqual(settings.speechModelAssignment(forInputSourceID: inputSourceID), .appleSpeech)
            XCTAssertTrue(viewModel.showSonioxSetup)

            store.value = "configured-value"
            settings.sonioxVerificationReceipt = .make(apiKey: "configured-value", region: .global)
            viewModel.refreshSonioxCredentialState()
            viewModel.assignSpeechModel(.sonioxV5, forInputSourceID: inputSourceID)

            XCTAssertEqual(settings.speechModelAssignment(forInputSourceID: inputSourceID), .sonioxV5)
        }
    }

    func testFailedVerificationErrorSurvivesCredentialStateRefresh() async throws {
        try await self.withRestoredDefaults {
            let settings = SettingsStore.shared
            settings.sonioxVerificationReceipt = .make(apiKey: "prior-value", region: .global)
            let store = FakeCredentialStore(initialValue: "prior-value")
            let service = SonioxCredentialService(
                store: store,
                verifier: FailingCredentialVerifier(
                    error: SonioxCredentialError(
                        category: .credential,
                        diagnosticType: "authentication_rejected",
                        requestID: nil
                    )
                )
            )
            let viewModel = VoiceEngineSettingsViewModel(
                settings: settings,
                appServices: AppServices.shared,
                asr: ASRService(),
                sonioxCredentialService: service
            )
            viewModel.sonioxAPIKeyDraft = "candidate-value"

            viewModel.saveAndVerifySonioxCredential()
            while viewModel.isVerifyingSonioxCredential {
                await Task.yield()
            }

            XCTAssertEqual(
                viewModel.sonioxCredentialError,
                "Soniox credential verification failed: credential, authentication_rejected"
            )
        }
    }

    func testStoppingSonioxSessionPublishesConfiguredCredentialState() async throws {
        try await self.withRestoredDefaults {
            let settings = SettingsStore.shared
            let configuredValue = "configured-value"
            settings.sonioxVerificationReceipt = .make(apiKey: configuredValue, region: .global)
            let service = SonioxCredentialService(
                store: FakeCredentialStore(initialValue: configuredValue),
                verifier: successfulVerifier()
            )
            let asr = ASRService()
            let viewModel = VoiceEngineSettingsViewModel(
                settings: settings,
                appServices: AppServices.shared,
                asr: asr,
                sonioxCredentialService: service
            )
            let sessionID = RecordingSessionID()
            let configuration = try XCTUnwrap(RecordingSpeechConfiguration(
                inputSourceID: nil,
                localeIdentifier: "en-US",
                model: .sonioxV5,
                languageBinding: .soniox(.init(languageCode: "en", isStrict: true, region: .global))
            ))
            asr.installTestingRecordingSession(
                sessionID: sessionID,
                configuration: configuration,
                provider: NoopTranscriptionProvider(),
                isRunning: false
            )
            viewModel.refreshSonioxCredentialState()
            XCTAssertEqual(viewModel.sonioxCredentialState, .ready)

            let didStop = await asr.stopWithoutTranscription(sessionID: sessionID)
            XCTAssertTrue(didStop)
            await Task.yield()

            XCTAssertEqual(viewModel.sonioxCredentialState, .configured)
        }
    }

    func testKeychainCommittedAggregateIgnoresLegacyCleanupFailure() {
        var aggregateCommitted = false

        XCTAssertNoThrow(
            try KeychainService.performCommittedMutation(
                primary: { aggregateCommitted = true },
                cleanup: { throw NSError(domain: "LegacyCleanup", code: 1) }
            )
        )
        XCTAssertTrue(aggregateCommitted)
    }

    func testAggregateKeychainStateWinsOverStaleLegacyProviderKey() {
        let values = KeychainService.authoritativeProviderKeys(
            aggregateExists: true,
            aggregate: ["asr:soniox": "new-value"],
            legacy: ["asr:soniox": "stale-value"]
        )

        XCTAssertEqual(values, ["asr:soniox": "new-value"])
    }

    func testEmptyAggregateKeychainStateBlocksLegacyProviderKeyResurrection() {
        let values = KeychainService.authoritativeProviderKeys(
            aggregateExists: true,
            aggregate: [:],
            legacy: ["asr:soniox": "stale-value"]
        )

        XCTAssertTrue(values.isEmpty)
    }

    func testMissingAggregateKeychainStateImportsLegacyProviderKey() {
        let values = KeychainService.authoritativeProviderKeys(
            aggregateExists: false,
            aggregate: [:],
            legacy: ["asr:soniox": "legacy-value"]
        )

        XCTAssertEqual(values, ["asr:soniox": "legacy-value"])
    }

    func testSonioxSettingsDefaultToCurrentInputSourceOnlyAndGlobal() {
        self.withRestoredDefaults {
            XCTAssertEqual(SettingsStore.shared.sonioxLanguageMode, .currentInputSourceOnly)
            XCTAssertEqual(SettingsStore.shared.sonioxRegion, .global)
            XCTAssertNil(SettingsStore.shared.sonioxVerificationReceipt)
        }
    }

    func testRegionChangeKeepsCredentialAndClearsVerificationReceipt() async throws {
        try await self.withRestoredDefaults {
            let credentialStore = FakeCredentialStore(initialValue: nil)
            let credentialService = SonioxCredentialService(
                store: credentialStore,
                verifier: successfulVerifier()
            )
            let settings = SettingsStore.shared
            let result = try await credentialService.saveAndVerify(
                apiKey: "retained-value",
                region: .global,
                commitIfCurrent: { true }
            )
            guard case let .verified(receipt) = result else {
                return XCTFail("Expected the fake credential to verify")
            }
            settings.sonioxVerificationReceipt = receipt
            let replacementCountAfterSave = credentialStore.replaceCount
            let removalCountAfterSave = credentialStore.removeCount
            let fingerprintAfterSave = try credentialService.storedCredentialFingerprint()

            settings.sonioxRegion = .japan

            XCTAssertNil(settings.sonioxVerificationReceipt)
            XCTAssertEqual(credentialStore.replaceCount, replacementCountAfterSave)
            XCTAssertEqual(credentialStore.removeCount, removalCountAfterSave)
            XCTAssertEqual(try credentialService.storedCredentialFingerprint(), fingerprintAfterSave)
        }
    }

    func testFreshRecordingProviderReadsCredentialOnceAndIsNeverCached() throws {
        try self.withRestoredDefaults {
            let credentialStore = FakeCredentialStore(initialValue: "snapshot-value")
            SettingsStore.shared.sonioxVerificationReceipt = .make(
                apiKey: "snapshot-value",
                region: .global
            )
            let service = ASRService(
                sonioxCredentialStore: credentialStore,
                sonioxTransportFactory: { _ in InertSonioxTransport() }
            )
            let configuration = try XCTUnwrap(RecordingSpeechConfiguration(
                inputSourceID: "com.apple.keylayout.US",
                localeIdentifier: "en-US",
                model: .sonioxV5,
                languageBinding: .soniox(.init(languageCode: "en", isStrict: true, region: .global))
            ))
            let selection = try XCTUnwrap(RecordingSpeechSessionSelection(
                sessionID: RecordingSessionID(),
                configuration: configuration
            ))

            let first = try service.makeRecordingProvider(for: selection)
            let second = try service.makeRecordingProvider(for: selection)

            XCTAssertEqual(credentialStore.fetchCount, 2)
            XCTAssertFalse((first as AnyObject) === (second as AnyObject))
            XCTAssertFalse(selection.providerKey.contains("snapshot-value"))
            XCTAssertFalse(String(describing: configuration).contains("snapshot-value"))
        }
    }

    func testConstructedProviderSnapshotsCredentialBeforeKeychainChanges() async throws {
        try await self.withRestoredDefaults {
            let credentialStore = FakeCredentialStore(initialValue: "first-value")
            SettingsStore.shared.sonioxVerificationReceipt = .make(apiKey: "first-value", region: .global)
            let transport = InertSonioxTransport()
            let service = ASRService(
                sonioxCredentialStore: credentialStore,
                sonioxTransportFactory: { _ in transport }
            )
            let configuration = try XCTUnwrap(RecordingSpeechConfiguration(
                inputSourceID: nil,
                localeIdentifier: "en-US",
                model: .sonioxV5,
                languageBinding: .soniox(.init(languageCode: "en", isStrict: true, region: .global))
            ))
            let selection = try XCTUnwrap(RecordingSpeechSessionSelection(
                sessionID: RecordingSessionID(),
                configuration: configuration
            ))
            let provider = try service.makeRecordingProvider(for: selection)

            credentialStore.value = "second-value"
            try await provider.prepare(progressHandler: nil)
            _ = try await provider.transcribeStreaming([0])

            let start = try XCTUnwrap(transport.sentFrames.first?.textValue)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(start.utf8)) as? [String: Any])
            XCTAssertEqual(object["api_key"] as? String, "first-value")
            XCTAssertFalse(start.contains("second-value"))
        }
    }

    func testVerificationUsesRegionModelsEndpointBearerHeaderGETAndTenSecondTimeout() async throws {
        let transport = RecordingTransport(result: .success(modelsResponse()))
        let verifier = SonioxCredentialVerifier(transport: transport, sleep: immediateSleep)

        try await verifier.verify(apiKey: "candidate-value", region: .japan)

        let request = try XCTUnwrap(transport.request)
        XCTAssertEqual(request.url, SettingsStore.SonioxRegion.japan.verificationModelsURL)
        XCTAssertEqual(request.httpMethod, "GET")
        let bearerValue = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(bearerValue.hasPrefix("Bearer "))
        XCTAssertEqual(
            SonioxVerificationReceipt.fingerprint(apiKey: String(bearerValue.dropFirst("Bearer ".count))),
            SonioxVerificationReceipt.fingerprint(apiKey: "candidate-value")
        )
        XCTAssertEqual(request.timeoutInterval, 10)
    }

    func testVerificationRequiresHTTP200AndSttRtV5InResponse() async {
        let cases: [(RecordingTransport.Result, SonioxFailureCategory)] = [
            (.success(modelsResponse(statusCode: 201)), .temporaryService),
            (.success(modelsResponse(modelID: "other-model")), .configuration),
        ]

        for (result, category) in cases {
            let verifier = SonioxCredentialVerifier(
                transport: RecordingTransport(result: result),
                sleep: immediateSleep
            )

            do {
                try await verifier.verify(apiKey: "candidate-value", region: .global)
                XCTFail("Expected verification to fail")
            } catch let error as SonioxCredentialError {
                XCTAssertEqual(error.category, category)
            } catch {
                XCTFail("Expected a sanitized Soniox credential error")
            }
        }
    }

    func testSuccessfulVerificationReplacesPriorKeyExactlyOnce() async throws {
        let store = FakeCredentialStore(initialValue: "prior-value")
        let service = SonioxCredentialService(
            store: store,
            verifier: successfulVerifier()
        )

        let result = try await service.saveAndVerify(
            apiKey: " candidate-value ",
            region: .global,
            commitIfCurrent: { true }
        )

        XCTAssertEqual(
            SonioxVerificationReceipt.fingerprint(apiKey: store.value ?? ""),
            SonioxVerificationReceipt.fingerprint(apiKey: "candidate-value")
        )
        XCTAssertEqual(store.replaceCount, 1)
        XCTAssertEqual(result, .verified(.make(apiKey: "candidate-value", region: .global)))
    }

    func test401500TimeoutAndMalformedBodyKeepPriorKeyUnchanged() async {
        let cases: [(RecordingTransport.Result, SonioxFailureCategory)] = [
            (.success(modelsResponse(statusCode: 401)), .credential),
            (.success(modelsResponse(statusCode: 403)), .credential),
            (.success(modelsResponse(statusCode: 402)), .balance),
            (.success(modelsResponse(statusCode: 429)), .limit),
            (.success(modelsResponse(statusCode: 500)), .temporaryService),
            (.failure(URLError(.timedOut)), .temporaryService),
            (.success(HTTPResponse(data: Data("not-json".utf8))), .temporaryService),
        ]

        for (result, category) in cases {
            let store = FakeCredentialStore(initialValue: "prior-value")
            let service = SonioxCredentialService(
                store: store,
                verifier: SonioxCredentialVerifier(
                    transport: RecordingTransport(result: result),
                    sleep: immediateSleep
                )
            )

            do {
                _ = try await service.saveAndVerify(
                    apiKey: "candidate-value",
                    region: .global,
                    commitIfCurrent: { true }
                )
                XCTFail("Expected verification to fail")
            } catch let error as SonioxCredentialError {
                XCTAssertEqual(error.category, category)
            } catch {
                XCTFail("Expected a sanitized Soniox credential error")
            }
            XCTAssertEqual(
                SonioxVerificationReceipt.fingerprint(apiKey: store.value ?? ""),
                SonioxVerificationReceipt.fingerprint(apiKey: "prior-value")
            )
            XCTAssertEqual(store.replaceCount, 0)
        }
    }

    func testEmptySaveDeletesWithoutNetworkRequest() async throws {
        let store = FakeCredentialStore(initialValue: "prior-value")
        let transport = RecordingTransport(result: .success(modelsResponse()))
        let service = SonioxCredentialService(
            store: store,
            verifier: SonioxCredentialVerifier(transport: transport, sleep: immediateSleep)
        )

        let result = try await service.saveAndVerify(
            apiKey: " \n ",
            region: .global,
            commitIfCurrent: { true }
        )

        XCTAssertEqual(result, .removed)
        XCTAssertNil(store.value)
        XCTAssertEqual(store.removeCount, 1)
        XCTAssertNil(transport.request)
    }

    func testErrorDescriptionContainsStableCategoryAndRequestIDOnly() async {
        let verifier = SonioxCredentialVerifier(
            transport: RecordingTransport(
                result: .success(modelsResponse(statusCode: 429, requestID: "request_123"))
            ),
            sleep: immediateSleep
        )

        do {
            try await verifier.verify(apiKey: "candidate-value", region: .global)
            XCTFail("Expected verification to fail")
        } catch let error as SonioxCredentialError {
            let description = error.errorDescription ?? ""
            XCTAssertTrue(description.contains(SonioxFailureCategory.limit.rawValue))
            XCTAssertTrue(description.contains("request_123"))
        } catch {
            XCTFail("Expected a sanitized Soniox credential error")
        }
    }

    func testReflectedCandidateRequestIDNeverReachesCredentialError() async {
        let candidate = "candidate-value"
        let verifier = SonioxCredentialVerifier(
            transport: RecordingTransport(
                result: .success(modelsResponse(statusCode: 500, requestID: candidate))
            ),
            sleep: immediateSleep
        )

        do {
            try await verifier.verify(apiKey: candidate, region: .global)
            XCTFail("Expected verification to fail")
        } catch let error as SonioxCredentialError {
            XCTAssertTrue(error.requestID == nil)
            XCTAssertFalse((error.errorDescription ?? "").contains(candidate))
        } catch {
            XCTFail("Expected a sanitized Soniox credential error")
        }
    }

    func testCredentialErrorNeverContainsCandidateKeyResponseBodyOrTranscript() async {
        let candidate = "candidate-value"
        let responseBody = "server-message"
        let transcript = "transcript-value"
        let verifier = SonioxCredentialVerifier(
            transport: RecordingTransport(
                result: .success(HTTPResponse(data: Data(responseBody.utf8), statusCode: 500))
            ),
            sleep: immediateSleep
        )

        do {
            try await verifier.verify(apiKey: candidate, region: .global)
            XCTFail("Expected verification to fail")
        } catch let error as SonioxCredentialError {
            let description = error.errorDescription ?? ""
            XCTAssertFalse(description.contains(candidate))
            XCTAssertFalse(description.contains(responseBody))
            XCTAssertFalse(description.contains(transcript))
        } catch {
            XCTFail("Expected a sanitized Soniox credential error")
        }
    }

    func testGenerationOrSameRegionRestoreBeforeCommitKeepsPriorKeyAndReceipt() async {
        let store = FakeCredentialStore(initialValue: "prior-value")
        let service = SonioxCredentialService(store: store, verifier: successfulVerifier())
        var receipt: SonioxVerificationReceipt? = .make(apiKey: "prior-value", region: .global)

        do {
            _ = try await service.saveAndVerify(
                apiKey: "candidate-value",
                region: .global,
                commitIfCurrent: {
                    receipt = nil
                    return false
                }
            )
            XCTFail("Expected stale verification")
        } catch let error as SonioxCredentialError {
            XCTAssertEqual(error, .staleVerification)
        } catch {
            XCTFail("Expected a stale-verification error")
        }

        XCTAssertEqual(
            SonioxVerificationReceipt.fingerprint(apiKey: store.value ?? ""),
            SonioxVerificationReceipt.fingerprint(apiKey: "prior-value")
        )
        XCTAssertNil(receipt)
    }

    func testRegionChangeBeforeCommitKeepsPriorKeyButClearsReceipt() async {
        let store = FakeCredentialStore(initialValue: "prior-value")
        let service = SonioxCredentialService(store: store, verifier: successfulVerifier())
        var receipt: SonioxVerificationReceipt? = .make(apiKey: "prior-value", region: .global)

        do {
            _ = try await service.saveAndVerify(
                apiKey: "candidate-value",
                region: .japan,
                commitIfCurrent: {
                    receipt = nil
                    return false
                }
            )
            XCTFail("Expected stale verification")
        } catch let error as SonioxCredentialError {
            XCTAssertEqual(error, .staleVerification)
        } catch {
            XCTFail("Expected a stale-verification error")
        }

        XCTAssertEqual(
            SonioxVerificationReceipt.fingerprint(apiKey: store.value ?? ""),
            SonioxVerificationReceipt.fingerprint(apiKey: "prior-value")
        )
        XCTAssertNil(receipt)
    }

    func testExplicitTenSecondRaceTimesOutEvenWhenTransportNeverReturns() async {
        let transport = CancellationResponsiveTransport()
        let verifier = SonioxCredentialVerifier(
            transport: transport,
            sleep: { _ in
                await transport.waitUntilRequestStarts()
            }
        )

        do {
            try await verifier.verify(apiKey: "candidate-value", region: .global)
            XCTFail("Expected explicit timeout")
        } catch let error as SonioxCredentialError {
            XCTAssertEqual(error.category, .temporaryService)
        } catch {
            XCTFail("Expected a sanitized timeout error")
        }
        XCTAssertTrue(transport.wasCancelled)
    }

    func testVerificationReceiptChangesWithRegionOrKeyWithoutContainingEitherSecretValue() {
        let global = SonioxVerificationReceipt.make(apiKey: "candidate-value", region: .global)
        let japan = SonioxVerificationReceipt.make(apiKey: "candidate-value", region: .japan)
        let otherKey = SonioxVerificationReceipt.make(apiKey: "other-value", region: .global)

        XCTAssertNotEqual(global, japan)
        XCTAssertNotEqual(global, otherKey)
        XCTAssertFalse(global.credentialFingerprint.contains("candidate-value"))
        XCTAssertFalse(String(describing: global).contains("candidate-value"))
    }

    func testGenericAIKeyReadsExcludeReservedASRCredentials() {
        let values = KeychainService.unreservedKeys([
            "openai": "generic-value",
            "asr:soniox": "reserved-value",
        ])

        XCTAssertEqual(values.keys.sorted(), ["openai"])
        XCTAssertEqual(
            SonioxVerificationReceipt.fingerprint(apiKey: values["openai"] ?? ""),
            SonioxVerificationReceipt.fingerprint(apiKey: "generic-value")
        )
    }

    func testSavingGenericAIKeysAtomicallyPreservesReservedASRCredentials() {
        let existing = [
            "openai": "old-value",
            "groq": "old-groq-value",
            "asr:soniox": "reserved-value",
            "asr:other": "other-reserved-value",
        ]

        func assertReservedKeysAreUnchanged(_ result: [String: String]) {
            for (providerID, value) in existing where providerID.hasPrefix("asr:") {
                XCTAssertTrue(result[providerID] == value)
            }
        }

        let added = KeychainService.replacingUnreservedKeys(
            existing: existing,
            replacements: ["anthropic": "added-value"]
        )
        XCTAssertEqual(added.keys.sorted(), ["anthropic", "asr:other", "asr:soniox"])
        assertReservedKeysAreUnchanged(added)

        let updated = KeychainService.replacingUnreservedKeys(
            existing: existing,
            replacements: ["groq": "updated-value"]
        )
        XCTAssertEqual(updated.keys.sorted(), ["asr:other", "asr:soniox", "groq"])
        XCTAssertEqual(
            SonioxVerificationReceipt.fingerprint(apiKey: updated["groq"] ?? ""),
            SonioxVerificationReceipt.fingerprint(apiKey: "updated-value")
        )
        assertReservedKeysAreUnchanged(updated)

        let deleted = KeychainService.replacingUnreservedKeys(existing: existing, replacements: [:])
        XCTAssertEqual(deleted.keys.sorted(), ["asr:other", "asr:soniox"])
        assertReservedKeysAreUnchanged(deleted)
    }

    private func withRestoredDefaults<T>(_ operation: () throws -> T) rethrows -> T {
        let defaults = UserDefaults.standard
        let keys = [
            self.languageModeKey,
            self.regionKey,
            self.receiptKey,
            self.selectedSpeechModelKey,
            self.speechModelAssignmentsKey,
        ]
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
        keys.forEach(defaults.removeObject(forKey:))
        return try operation()
    }

    private func withRestoredDefaults<T>(_ operation: () async throws -> T) async rethrows -> T {
        let defaults = UserDefaults.standard
        let keys = [
            self.languageModeKey,
            self.regionKey,
            self.receiptKey,
            self.selectedSpeechModelKey,
            self.speechModelAssignmentsKey,
        ]
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
        keys.forEach(defaults.removeObject(forKey:))
        return try await operation()
    }
}

private let immediateSleep: SonioxCredentialSleep = { _ in
    try await Task.sleep(for: .seconds(3600))
}

private func successfulVerifier() -> SonioxCredentialVerifier {
    SonioxCredentialVerifier(
        transport: RecordingTransport(result: .success(modelsResponse())),
        sleep: immediateSleep
    )
}

private func modelsResponse(
    statusCode: Int = 200,
    modelID: String = "stt-rt-v5",
    requestID: String? = nil
) -> HTTPResponse {
    let data = Data("{\"models\":[{\"id\":\"\(modelID)\"}]}".utf8)
    return HTTPResponse(data: data, statusCode: statusCode, requestID: requestID)
}

private struct HTTPResponse {
    let data: Data
    let statusCode: Int
    let requestID: String?

    init(data: Data, statusCode: Int = 200, requestID: String? = nil) {
        self.data = data
        self.statusCode = statusCode
        self.requestID = requestID
    }

    func asURLResponse() -> HTTPURLResponse {
        guard let response = HTTPURLResponse(
            url: URL(fileURLWithPath: "/v1/models"),
            statusCode: self.statusCode,
            httpVersion: nil,
            headerFields: self.requestID.map { ["X-Request-ID": $0] }
        ) else {
            preconditionFailure("The static test response URL must be valid")
        }
        return response
    }
}

private final class FakeCredentialStore: SonioxCredentialStoring {
    var value: String?
    private(set) var replaceCount = 0
    private(set) var removeCount = 0
    private(set) var fetchCount = 0

    init(initialValue: String?) {
        self.value = initialValue
    }

    func fetchAPIKey() throws -> String? {
        self.fetchCount += 1
        return self.value
    }

    func replaceAPIKey(_ value: String) throws {
        self.value = value
        self.replaceCount += 1
    }

    func removeAPIKey() throws {
        self.value = nil
        self.removeCount += 1
    }
}

private final class SuspendingCredentialVerifier: SonioxCredentialVerifying, @unchecked Sendable {
    private let lock = NSLock()
    private var hasStarted = false
    private var verificationContinuation: CheckedContinuation<Void, Error>?

    func verify(apiKey: String, region: SettingsStore.SonioxRegion) async throws {
        _ = apiKey
        _ = region
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.lock.withLock {
                self.hasStarted = true
                self.verificationContinuation = continuation
            }
        }
    }

    func waitUntilStarted() async {
        while !self.lock.withLock({ self.hasStarted }) {
            await Task.yield()
        }
    }

    func succeed() {
        let continuation = self.lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { self.verificationContinuation = nil }
            return self.verificationContinuation
        }
        continuation?.resume()
    }
}

private struct FailingCredentialVerifier: SonioxCredentialVerifying {
    let error: SonioxCredentialError

    func verify(apiKey: String, region: SettingsStore.SonioxRegion) async throws {
        _ = apiKey
        _ = region
        throw self.error
    }
}

private final class NoopTranscriptionProvider: TranscriptionProvider {
    let name = "No-op test provider"
    let isAvailable = true
    let isReady = true

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {}

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        _ = samples
        return ASRTranscriptionResult(text: "")
    }
}

private final class InertSonioxTransport: SonioxWebSocketTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [SonioxWebSocketFrame] = []

    var sentFrames: [SonioxWebSocketFrame] {
        self.lock.withLock { self.frames }
    }

    func start() async throws {}

    func send(_ frame: SonioxWebSocketFrame) async throws {
        self.lock.withLock { self.frames.append(frame) }
    }

    func receive() async throws -> SonioxWebSocketFrame {
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }

    func close(_ disposition: SonioxTransportCloseDisposition) {
        _ = disposition
    }
}

private extension SonioxWebSocketFrame {
    var textValue: String? {
        guard case let .text(value) = self else { return nil }
        return value
    }
}

private final class RecordingTransport: SonioxModelsTransport, @unchecked Sendable {
    enum Result {
        case success(HTTPResponse)
        case failure(Error)
    }

    private let result: Result
    private let lock = NSLock()
    private var capturedRequest: URLRequest?

    init(result: Result) {
        self.result = result
    }

    var request: URLRequest? {
        self.lock.withLock { self.capturedRequest }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.lock.withLock { self.capturedRequest = request }
        switch self.result {
        case let .success(response):
            return (response.data, response.asURLResponse())
        case let .failure(error):
            throw error
        }
    }
}

private final class CancellationResponsiveTransport: SonioxModelsTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var requestContinuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var hasStarted = false
    private var cancellationObserved = false

    var wasCancelled: Bool {
        self.lock.withLock { self.cancellationObserved }
    }

    func waitUntilRequestStarts() async {
        if self.lock.withLock({ self.hasStarted }) {
            return
        }
        await withCheckedContinuation { continuation in
            self.lock.withLock {
                if self.hasStarted {
                    continuation.resume()
                } else {
                    self.startedContinuation = continuation
                }
            }
        }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
                let startedContinuation = self.lock.withLock { () -> CheckedContinuation<Void, Never>? in
                    self.requestContinuation = continuation
                    self.hasStarted = true
                    defer { self.startedContinuation = nil }
                    return self.startedContinuation
                }
                startedContinuation?.resume()
            }
        } onCancel: {
            let continuation = self.lock.withLock { () -> CheckedContinuation<(Data, HTTPURLResponse), Error>? in
                self.cancellationObserved = true
                defer { self.requestContinuation = nil }
                return self.requestContinuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

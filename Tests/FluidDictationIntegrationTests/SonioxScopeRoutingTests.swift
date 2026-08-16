@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class SonioxScopeRoutingTests: XCTestCase {
    private let selectedModelKey = "SelectedSpeechModel"
    private let localFallbackKey = "LocalFallbackSpeechModel"

    func testHiddenSonioxMetadataIsCloudStreamingNoArtifactAndNotSelectable() {
        let model = SettingsStore.SpeechModel.sonioxV5

        XCTAssertTrue(model.isCloudSpeechModel)
        XCTAssertTrue(model.requiresCredential)
        XCTAssertFalse(model.requiresModelDownload)
        XCTAssertEqual(model.backendModelIdentifier, SonioxProvider.modelID)
        XCTAssertEqual(model.provider, .soniox)
        XCTAssertEqual(model.displayName, "Soniox v5 Realtime")
        XCTAssertTrue(model.supportsStreaming)
        XCTAssertTrue(model.isInstalled)
        XCTAssertEqual(model.expectedDownloadBytes, 0)
        XCTAssertFalse(SettingsStore.SpeechModel.availableModels.contains(model))
        XCTAssertFalse(SettingsStore.SpeechModel.models(for: .soniox).contains(model))
    }

    func testActivatingLocalModelUpdatesLocalFallback() {
        self.withRestoredSpeechDefaults {
            let settings = SettingsStore.shared
            settings.selectedSpeechModel = .appleSpeech

            XCTAssertEqual(settings.localFallbackSpeechModel, .appleSpeech)
        }
    }

    func testActivatingSonioxPreservesPriorLocalFallback() {
        self.withRestoredSpeechDefaults {
            let defaults = UserDefaults.standard
            let settings = SettingsStore.shared
            settings.selectedSpeechModel = .appleSpeech
            settings.selectedSpeechModel = .sonioxV5

            XCTAssertEqual(defaults.string(forKey: self.selectedModelKey), SettingsStore.SpeechModel.sonioxV5.rawValue)
            XCTAssertEqual(settings.selectedSpeechModel, SettingsStore.SpeechModel.defaultModel)
            XCTAssertEqual(defaults.string(forKey: self.selectedModelKey), SettingsStore.SpeechModel.defaultModel.rawValue)
            XCTAssertEqual(settings.localFallbackSpeechModel, .appleSpeech)
        }
    }

    func testMissingInvalidCloudOrUnsupportedFallbackNormalizesToPlatformDefault() {
        let defaultModel = SettingsStore.SpeechModel.whisperBase
        let available: [SettingsStore.SpeechModel] = [.appleSpeech, defaultModel]

        XCTAssertEqual(
            SettingsStore.normalizedLocalFallbackSpeechModel(
                nil,
                availableModels: available,
                defaultModel: defaultModel
            ),
            defaultModel
        )
        XCTAssertEqual(
            SettingsStore.normalizedLocalFallbackSpeechModel(
                .sonioxV5,
                availableModels: available,
                defaultModel: defaultModel
            ),
            defaultModel
        )
        XCTAssertEqual(
            SettingsStore.normalizedLocalFallbackSpeechModel(
                .parakeetTDT,
                availableModels: available,
                defaultModel: defaultModel
            ),
            defaultModel
        )
    }

    func testLegacyInstallInitializesFallbackFromCurrentLocalSelection() {
        self.withRestoredSpeechDefaults {
            let defaults = UserDefaults.standard
            defaults.set(SettingsStore.SpeechModel.appleSpeech.rawValue, forKey: self.selectedModelKey)
            defaults.removeObject(forKey: self.localFallbackKey)

            XCTAssertEqual(SettingsStore.shared.localFallbackSpeechModel, .appleSpeech)
            XCTAssertEqual(defaults.string(forKey: self.localFallbackKey), SettingsStore.SpeechModel.appleSpeech.rawValue)
        }
    }

    func testPresentWrongTypedFallbackNormalizesToPlatformDefault() {
        self.withRestoredSpeechDefaults {
            let defaults = UserDefaults.standard
            let settings = SettingsStore.shared
            settings.selectedSpeechModel = .appleSpeech
            defaults.set(Data([0x01, 0x02]), forKey: self.localFallbackKey)

            XCTAssertEqual(settings.localFallbackSpeechModel, SettingsStore.SpeechModel.defaultModel)
            XCTAssertEqual(
                defaults.string(forKey: self.localFallbackKey),
                SettingsStore.SpeechModel.defaultModel.rawValue
            )
        }
    }

    func testBackupRoundTripsFallbackAndRejectsCloudFallback() throws {
        try self.withRestoredSpeechDefaults {
            let settings = SettingsStore.shared
            settings.selectedSpeechModel = .appleSpeech
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(settings.makeBackupPayload())) as? [String: Any]
            )

            XCTAssertEqual(object["localFallbackSpeechModelID"] as? String, SettingsStore.SpeechModel.appleSpeech.rawValue)

            settings.selectedSpeechModel = .whisperBase
            settings.localFallbackSpeechModel = .whisperBase
            let localPayload = try JSONDecoder().decode(
                SettingsBackupPayload.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
            settings.restore(from: localPayload)
            XCTAssertEqual(settings.localFallbackSpeechModel, .appleSpeech)

            object["localFallbackSpeechModelID"] = SettingsStore.SpeechModel.sonioxV5.rawValue
            let cloudPayload = try JSONDecoder().decode(
                SettingsBackupPayload.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
            settings.restore(from: cloudPayload)
            XCTAssertEqual(settings.localFallbackSpeechModel, SettingsStore.SpeechModel.defaultModel)

            object["localFallbackSpeechModelID"] = "unknown-fallback"
            let unknownPayload = try JSONDecoder().decode(
                SettingsBackupPayload.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
            settings.restore(from: unknownPayload)
            XCTAssertEqual(settings.localFallbackSpeechModel, SettingsStore.SpeechModel.defaultModel)

            object["selectedSpeechModel"] = SettingsStore.SpeechModel.sonioxV5.rawValue
            let hiddenCloudPayload = try JSONDecoder().decode(
                SettingsBackupPayload.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
            settings.restore(from: hiddenCloudPayload)
            XCTAssertEqual(settings.selectedSpeechModel, SettingsStore.SpeechModel.defaultModel)
            XCTAssertEqual(
                UserDefaults.standard.string(forKey: self.selectedModelKey),
                SettingsStore.SpeechModel.defaultModel.rawValue
            )

            let encoded = try XCTUnwrap(
                String(data: JSONEncoder().encode(settings.makeBackupPayload()), encoding: .utf8)
            )
            XCTAssertFalse(encoded.localizedCaseInsensitiveContains("credential"))
            XCTAssertFalse(encoded.localizedCaseInsensitiveContains("verification"))
        }
    }

    func testExplicitCloudLifecycleRequestRejectsAtLocalOnlyBoundary() async {
        let asr = ASRService()

        do {
            try await asr.clearModelCache(for: .sonioxV5)
            XCTFail("Expected hidden cloud model cache request to fail")
        } catch {
            let error = error as NSError
            XCTAssertEqual(error.domain, "ASRService.LocalOnly")
            XCTAssertEqual(error.code, -2100)
        }
    }

    func testDictionaryTrainingUsesLocalFallbackWhenGlobalModelIsSoniox() async {
        await self.withRestoredSpeechDefaults {
            let settings = SettingsStore.shared
            settings.selectedSpeechModel = .appleSpeech
            settings.selectedSpeechModel = .sonioxV5
            let factory = CountingLocalProviderFactory()
            let asr = ASRService(localProviderFactory: factory.make(configuration:))
            var capturedConfigurations: [RecordingSpeechConfiguration] = []
            var dictionaryTrainingFlags: [Bool] = []
            var captureCallbackPresence: [Bool] = []
            var automaticCaptureStarted = 0
            let starter = DictionaryTrainingRecordingStarter { configuration, forDictionaryTraining, onCaptureStarted in
                capturedConfigurations.append(configuration)
                dictionaryTrainingFlags.append(forDictionaryTraining)
                captureCallbackPresence.append(onCaptureStarted != nil)
                _ = try? await asr.preparedLocalProvider(for: configuration)
                onCaptureStarted?()
                return .failed
            }

            _ = await starter.startAutomaticCapture {
                automaticCaptureStarted += 1
            }
            _ = await starter.startCustomSample()

            XCTAssertEqual(capturedConfigurations.map(\.model), [.appleSpeech, .appleSpeech])
            XCTAssertTrue(capturedConfigurations.allSatisfy { !$0.model.isCloudSpeechModel })
            XCTAssertEqual(dictionaryTrainingFlags, [true, true])
            XCTAssertEqual(captureCallbackPresence, [true, false])
            XCTAssertEqual(automaticCaptureStarted, 1)
            XCTAssertEqual(factory.requestedModels, [.appleSpeech, .appleSpeech])
            XCTAssertEqual(factory.prepareCount, 2)
        }
    }

    func testFileAndMeetingUseLocalFallbackWhenGlobalModelIsSoniox() async throws {
        try await self.withRestoredSpeechDefaults {
            let settings = SettingsStore.shared
            settings.selectedSpeechModel = .appleSpeech
            settings.selectedSpeechModel = .sonioxV5
            let factory = CountingLocalProviderFactory()
            let asr = ASRService(localProviderFactory: factory.make(configuration:))
            let fileURL = try self.fixtureURL()

            _ = try await asr.transcribeFileForAPI(fileURL)
            let meeting = MeetingTranscriptionService(asrService: asr)
            _ = try await meeting.transcribeFile(fileURL)

            XCTAssertEqual(factory.requestedModels, [.appleSpeech, .appleSpeech])
            XCTAssertEqual(factory.prepareCount, 2)
            XCTAssertEqual(factory.fileTranscriptionCount, 2)
            XCTAssertEqual(factory.createdProviderCount, 2)
        }
    }

    func testLocalAPISampleAndFileUseLocalFallbackAndReportItsName() async throws {
        try await self.withRestoredSpeechDefaults {
            let settings = SettingsStore.shared
            settings.selectedSpeechModel = .appleSpeech
            settings.selectedSpeechModel = .sonioxV5
            let factory = CountingLocalProviderFactory()
            let asr = ASRService(localProviderFactory: factory.make(configuration:))
            let controller = InferenceAPIController(asrService: asr, settings: settings)
            let fileURL = try self.fixtureURL()

            let sampleResponse = try await controller.handle(LocalAPI.Request(
                method: "POST",
                path: "/v1/transcribe",
                query: [:],
                headers: ["x-filename": fileURL.lastPathComponent],
                body: Data(contentsOf: fileURL)
            ))
            let fileBody = try JSONSerialization.data(withJSONObject: ["path": fileURL.path])
            let fileResponse = await controller.handle(LocalAPI.Request(
                method: "POST",
                path: "/v1/transcribe",
                query: [:],
                headers: ["content-type": "application/json"],
                body: fileBody
            ))

            XCTAssertEqual(sampleResponse.status, 200)
            XCTAssertEqual(fileResponse.status, 200)
            XCTAssertEqual(try self.providerName(from: sampleResponse), SettingsStore.SpeechModel.appleSpeech.displayName)
            XCTAssertEqual(try self.providerName(from: fileResponse), SettingsStore.SpeechModel.appleSpeech.displayName)
            XCTAssertEqual(factory.requestedModels, [.appleSpeech, .appleSpeech])
            XCTAssertEqual(factory.prepareCount, 2)
            XCTAssertEqual(factory.sampleTranscriptionCount, 1)
            XCTAssertEqual(factory.fileTranscriptionCount, 1)
        }
    }

    func testLocalAPISampleResponseKeepsProviderIdentityCapturedAtRequestStart() async throws {
        try await self.withRestoredSpeechDefaults {
            let settings = SettingsStore.shared
            settings.selectedSpeechModel = .appleSpeech
            let factory = SuspendingLocalProviderFactory()
            let asr = ASRService(localProviderFactory: factory.make(configuration:))
            let controller = InferenceAPIController(asrService: asr, settings: settings)
            let fileURL = try self.fixtureURL()
            let request = try LocalAPI.Request(
                method: "POST",
                path: "/v1/transcribe",
                query: [:],
                headers: ["x-filename": fileURL.lastPathComponent],
                body: Data(contentsOf: fileURL)
            )

            let responseTask = Task { await controller.handle(request) }
            await factory.waitUntilTranscriptionSuspends()
            settings.selectedSpeechModel = .whisperBase
            factory.resumeTranscription()
            let response = await responseTask.value

            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(try self.providerName(from: response), SettingsStore.SpeechModel.appleSpeech.displayName)
            XCTAssertEqual(factory.requestedModels, [.appleSpeech])
        }
    }

    func testLocalAPIFileResponseKeepsProviderIdentityCapturedAtRequestStart() async throws {
        try await self.withRestoredSpeechDefaults {
            let settings = SettingsStore.shared
            settings.selectedSpeechModel = .appleSpeech
            let factory = SuspendingLocalProviderFactory()
            let asr = ASRService(localProviderFactory: factory.make(configuration:))
            let controller = InferenceAPIController(asrService: asr, settings: settings)
            let fileURL = try self.fixtureURL()
            let body = try JSONSerialization.data(withJSONObject: ["path": fileURL.path])
            let request = LocalAPI.Request(
                method: "POST",
                path: "/v1/transcribe",
                query: [:],
                headers: ["content-type": "application/json"],
                body: body
            )

            let responseTask = Task { await controller.handle(request) }
            await factory.waitUntilTranscriptionSuspends()
            settings.selectedSpeechModel = .whisperBase
            factory.resumeTranscription()
            let response = await responseTask.value

            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(try self.providerName(from: response), SettingsStore.SpeechModel.appleSpeech.displayName)
            XCTAssertEqual(factory.requestedModels, [.appleSpeech])
        }
    }

    private func fixtureURL() throws -> URL {
        try XCTUnwrap(Bundle(for: SonioxScopeRoutingTests.self).url(forResource: "dictation_fixture", withExtension: "wav"))
    }

    private func providerName(from response: LocalAPI.Response) throws -> String {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        return try XCTUnwrap(object["provider"] as? String)
    }

    private func withRestoredSpeechDefaults<T>(_ operation: () throws -> T) rethrows -> T {
        let defaults = UserDefaults.standard
        let selected = defaults.object(forKey: self.selectedModelKey)
        let fallback = defaults.object(forKey: self.localFallbackKey)
        defer {
            self.restore(selected, forKey: self.selectedModelKey, defaults: defaults)
            self.restore(fallback, forKey: self.localFallbackKey, defaults: defaults)
        }
        defaults.removeObject(forKey: self.selectedModelKey)
        defaults.removeObject(forKey: self.localFallbackKey)
        return try operation()
    }

    private func withRestoredSpeechDefaults<T>(_ operation: () async throws -> T) async rethrows -> T {
        let defaults = UserDefaults.standard
        let selected = defaults.object(forKey: self.selectedModelKey)
        let fallback = defaults.object(forKey: self.localFallbackKey)
        defer {
            self.restore(selected, forKey: self.selectedModelKey, defaults: defaults)
            self.restore(fallback, forKey: self.localFallbackKey, defaults: defaults)
        }
        defaults.removeObject(forKey: self.selectedModelKey)
        defaults.removeObject(forKey: self.localFallbackKey)
        return try await operation()
    }

    private func restore(_ value: Any?, forKey key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

@MainActor
private final class CountingLocalProviderFactory {
    private(set) var requestedModels: [SettingsStore.SpeechModel] = []
    private(set) var createdProviderCount = 0
    private(set) var prepareCount = 0
    private(set) var sampleTranscriptionCount = 0
    private(set) var fileTranscriptionCount = 0

    func make(configuration: RecordingSpeechConfiguration) throws -> TranscriptionProvider {
        self.requestedModels.append(configuration.model)
        self.createdProviderCount += 1
        return CountingLocalProvider(owner: self)
    }

    func prepared() {
        self.prepareCount += 1
    }

    func transcribedSamples() {
        self.sampleTranscriptionCount += 1
    }

    func transcribedFile() {
        self.fileTranscriptionCount += 1
    }
}

@MainActor
private final class CountingLocalProvider: TranscriptionProvider {
    let name = "Fake local provider"
    let isAvailable = true
    private(set) var isReady = false
    let prefersNativeFileTranscription = true
    private unowned let owner: CountingLocalProviderFactory

    init(owner: CountingLocalProviderFactory) {
        self.owner = owner
    }

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
        self.owner.prepared()
        self.isReady = true
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        self.owner.transcribedSamples()
        return ASRTranscriptionResult(text: "local sample", confidence: 0.9)
    }

    func transcribeFile(at fileURL: URL) async throws -> ASRTranscriptionResult {
        self.owner.transcribedFile()
        return ASRTranscriptionResult(text: "local file", confidence: 0.95)
    }
}

@MainActor
private final class SuspendingLocalProviderFactory {
    private(set) var requestedModels: [SettingsStore.SpeechModel] = []
    private var transcriptionContinuation: CheckedContinuation<Void, Never>?
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var transcriptionIsSuspended = false

    func make(configuration: RecordingSpeechConfiguration) throws -> TranscriptionProvider {
        self.requestedModels.append(configuration.model)
        return SuspendingLocalProvider(owner: self)
    }

    func suspendTranscription() async {
        await withCheckedContinuation { continuation in
            self.transcriptionContinuation = continuation
            self.transcriptionIsSuspended = true
            let waiters = self.suspensionWaiters
            self.suspensionWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilTranscriptionSuspends() async {
        guard !self.transcriptionIsSuspended else { return }
        await withCheckedContinuation { continuation in
            self.suspensionWaiters.append(continuation)
        }
    }

    func resumeTranscription() {
        self.transcriptionIsSuspended = false
        self.transcriptionContinuation?.resume()
        self.transcriptionContinuation = nil
    }
}

@MainActor
private final class SuspendingLocalProvider: TranscriptionProvider {
    let name = "Suspending local provider"
    let isAvailable = true
    private(set) var isReady = false
    let prefersNativeFileTranscription = true
    private unowned let owner: SuspendingLocalProviderFactory

    init(owner: SuspendingLocalProviderFactory) {
        self.owner = owner
    }

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
        self.isReady = true
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        await self.owner.suspendTranscription()
        return ASRTranscriptionResult(text: "local sample", confidence: 0.9)
    }

    func transcribeFile(at fileURL: URL) async throws -> ASRTranscriptionResult {
        await self.owner.suspendTranscription()
        return ASRTranscriptionResult(text: "local file", confidence: 0.95)
    }
}

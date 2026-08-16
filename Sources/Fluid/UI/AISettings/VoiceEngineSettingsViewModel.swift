import AppKit
import Combine
import SwiftUI

@MainActor
final class VoiceEngineSettingsViewModel: ObservableObject {
    let settings: SettingsStore
    private let appServices: AppServices
    private let asrOverride: ASRService?
    private let sonioxCredentialService: SonioxCredentialService
    private var cancellables = Set<AnyCancellable>()
    private var sonioxMutationTask: Task<Void, Never>?
    private var sonioxMutationGeneration: UInt64 = 0
    private var settingsBackupRestoreObserver: NSObjectProtocol?

    var asr: ASRService {
        self.asrOverride ?? self.appServices.asr
    }

    var areSpeechModelActionsBlocked: Bool {
        self.asr.isRunning
            || self.downloadingModel != nil
            || self.asr.hasActiveModelDownload
            || self.asr.hasActiveModelPreparation
            || self.asr.isCancellingModelPreparation
            || self.asr.hasActiveRecordingSession
            || self.asr.isRunningOrStarting
            || (!self.asr.isAsrReady && (self.asr.isDownloadingModel || self.asr.isLoadingModel))
    }

    @Published var modelSortOption: ModelSortOption = .provider
    @Published var providerFilter: SpeechProviderFilter = .all
    @Published var englishOnlyFilter: Bool = false
    @Published var installedOnlyFilter: Bool = false
    @Published var showSpeechFilters: Bool = false

    @Published var selectedSpeechProvider: SettingsStore.SpeechModel.Provider
    @Published var previewSpeechModel: SettingsStore.SpeechModel
    @Published var showAdvancedSpeechInfo: Bool = false
    @Published var suppressSpeechProviderSync: Bool = false
    @Published var skipNextSpeechModelSync: Bool = false
    @Published var sonioxAPIKeyDraft = ""
    @Published private(set) var sonioxStoredCredentialFingerprint: String?
    @Published private(set) var sonioxCredentialState: SonioxCredentialState = .apiKeyRequired
    @Published private(set) var isVerifyingSonioxCredential = false
    @Published private(set) var sonioxCredentialError: String?
    @Published var showSonioxSetup = false

    var downloadingModel: SettingsStore.SpeechModel? {
        guard let modelID = self.asr.downloadingModelId else { return nil }
        return SettingsStore.SpeechModel.allCases.first { $0.id == modelID }
    }

    var downloadProgress: Double {
        self.asr.downloadProgress ?? 0.0
    }

    var isCancellingModelDownload: Bool {
        self.asr.isCancellingModelDownload
    }

    @Published var removeFillerWordsEnabled: Bool

    init(
        settings: SettingsStore,
        appServices: AppServices,
        asr: ASRService? = nil,
        sonioxCredentialService: SonioxCredentialService? = nil
    ) {
        self.settings = settings
        self.appServices = appServices
        self.asrOverride = asr
        self.sonioxCredentialService = sonioxCredentialService ?? SonioxCredentialService()
        self.previewSpeechModel = settings.selectedSpeechModel
        self.selectedSpeechProvider = settings.selectedSpeechModel.provider
        self.removeFillerWordsEnabled = settings.removeFillerWordsEnabled
        appServices.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.refreshSonioxCredentialState()
                    self.objectWillChange.send()
                }
            }
            .store(in: &self.cancellables)
        settings.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.refreshSonioxCredentialState()
                    self.objectWillChange.send()
                }
            }
            .store(in: &self.cancellables)
        self.settingsBackupRestoreObserver = NotificationCenter.default.addObserver(
            forName: .settingsBackupDidRestore,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.invalidateSonioxCredentialMutation()
                self.refreshSonioxCredentialState()
                self.objectWillChange.send()
            }
        }
        self.refreshSonioxCredentialState()
    }

    deinit {
        self.sonioxMutationTask?.cancel()
        if let observer = self.settingsBackupRestoreObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func onAppear() {
        self.previewSpeechModel = self.settings.selectedSpeechModel
        self.selectedSpeechProvider = self.settings.selectedSpeechModel.provider
        self.removeFillerWordsEnabled = self.settings.removeFillerWordsEnabled
        self.refreshSonioxCredentialState()

        Task {
            await self.asr.checkIfModelsExistAsync()
        }
    }

    func handleSelectedSpeechModelChange(_ newValue: SettingsStore.SpeechModel) {
        if self.skipNextSpeechModelSync {
            self.skipNextSpeechModelSync = false
            return
        }
        guard !self.suppressSpeechProviderSync else { return }
        self.previewSpeechModel = newValue
        self.setSelectedSpeechProvider(newValue.provider)
    }

    var sonioxCredentialMutationBlocked: Bool {
        self.isVerifyingSonioxCredential || self.asr.hasActiveRecordingSession || self.asr.isRunningOrStarting
    }

    static func shouldRouteSonioxAssignmentToSetup(
        model: SettingsStore.SpeechModel,
        credentialState: SonioxCredentialState
    ) -> Bool {
        model.isCloudSpeechModel && credentialState != .configured && credentialState != .ready
    }

    func refreshSonioxCredentialState() {
        do {
            self.sonioxStoredCredentialFingerprint = try self.sonioxCredentialService.storedCredentialFingerprint()
            self.sonioxCredentialError = nil
        } catch {
            self.sonioxStoredCredentialFingerprint = nil
            self.sonioxCredentialError = "Unable to read Soniox credential state."
        }
        self.sonioxCredentialState = SonioxCredentialStateResolver.resolve(
            cachedCredentialFingerprint: self.sonioxStoredCredentialFingerprint,
            verificationReceipt: self.settings.sonioxVerificationReceipt,
            selectedRegion: self.settings.sonioxRegion,
            isVerifying: self.isVerifyingSonioxCredential,
            activeRecordingModel: self.asr.activeRecordingSpeechModel
        )
    }

    func requestSonioxSetup() {
        self.showSonioxSetup = true
        self.previewSpeechModel = .sonioxV5
        self.selectedSpeechProvider = .soniox
    }

    func setSonioxRegion(_ region: SettingsStore.SonioxRegion) {
        guard !self.sonioxCredentialMutationBlocked else { return }
        self.settings.sonioxRegion = region
        self.refreshSonioxCredentialState()
    }

    func saveAndVerifySonioxCredential() {
        guard !self.sonioxCredentialMutationBlocked else { return }
        let generation = self.sonioxMutationGeneration &+ 1
        self.sonioxMutationGeneration = generation
        let region = self.settings.sonioxRegion
        let candidate = self.sonioxAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.isEmpty == false else { return }
        self.sonioxCredentialError = nil
        self.isVerifyingSonioxCredential = true
        self.refreshSonioxCredentialState()
        self.sonioxMutationTask?.cancel()
        self.sonioxMutationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.sonioxMutationGeneration == generation {
                    self.isVerifyingSonioxCredential = false
                    self.sonioxMutationTask = nil
                    self.refreshSonioxCredentialState()
                }
            }
            do {
                let result = try await self.sonioxCredentialService.saveAndVerify(
                    apiKey: candidate,
                    region: region,
                    commitIfCurrent: { [weak self] in
                        guard let self,
                              self.sonioxMutationGeneration == generation,
                              self.isVerifyingSonioxCredential,
                              self.settings.sonioxRegion == region,
                              !self.asr.hasActiveRecordingSession
                        else { return false }
                        return true
                    }
                )
                guard self.sonioxMutationGeneration == generation else { return }
                switch result {
                case .removed:
                    self.settings.sonioxVerificationReceipt = nil
                    self.sonioxAPIKeyDraft = ""
                case let .verified(receipt):
                    self.settings.sonioxVerificationReceipt = receipt
                    self.sonioxAPIKeyDraft = ""
                }
            } catch is CancellationError {
                guard self.sonioxMutationGeneration == generation else { return }
                self.sonioxCredentialError = "Verification was cancelled."
            } catch let error as SonioxCredentialError {
                guard self.sonioxMutationGeneration == generation else { return }
                self.sonioxCredentialError = error.errorDescription ?? "Soniox credential verification failed."
            } catch {
                guard self.sonioxMutationGeneration == generation else { return }
                self.sonioxCredentialError = "Soniox credential verification failed."
            }
        }
    }

    func removeSonioxCredential() {
        guard !self.sonioxCredentialMutationBlocked else { return }
        self.sonioxMutationGeneration &+= 1
        self.sonioxMutationTask?.cancel()
        self.sonioxMutationTask = nil
        do {
            try self.sonioxCredentialService.remove()
            self.settings.sonioxVerificationReceipt = nil
            self.sonioxAPIKeyDraft = ""
            self.sonioxCredentialError = nil
        } catch {
            self.sonioxCredentialError = "Unable to remove the Soniox credential."
        }
        self.refreshSonioxCredentialState()
    }

    private func invalidateSonioxCredentialMutation() {
        self.sonioxMutationGeneration &+= 1
        self.sonioxMutationTask?.cancel()
        self.sonioxMutationTask = nil
        self.isVerifyingSonioxCredential = false
    }

    func assignSpeechModel(_ model: SettingsStore.SpeechModel, forInputSourceID inputSourceID: String) {
        guard !self.areSpeechModelActionsBlocked else { return }
        if Self.shouldRouteSonioxAssignmentToSetup(
            model: model,
            credentialState: self.sonioxCredentialState
        ) {
            self.requestSonioxSetup()
            return
        }
        self.settings.setSpeechModelAssignment(model, forInputSourceID: inputSourceID)
    }

    var filteredSpeechModels: [SettingsStore.SpeechModel] {
        var models = SettingsStore.SpeechModel.availableModels

        switch self.providerFilter {
        case .all:
            break
        case .nvidia:
            models = models.filter { $0.provider == .nvidia }
        case .apple:
            models = models.filter { $0.provider == .apple }
        case .cohere:
            models = models.filter { $0.provider == .cohere }
        case .openai:
            models = models.filter { $0.provider == .openai }
        case .soniox:
            models = models.filter { $0.provider == .soniox }
        }

        if self.englishOnlyFilter {
            models = models.filter { model in
                let label = model.languageSupport.lowercased()
                let title = model.humanReadableName.lowercased()
                return label.contains("english only") || title.contains("english")
            }
        }

        if self.installedOnlyFilter {
            models = models.filter { $0.isInstalled }
        }

        switch self.modelSortOption {
        case .provider:
            models.sort { $0.brandName.localizedCaseInsensitiveCompare($1.brandName) == .orderedAscending }
        case .accuracy:
            models.sort { $0.accuracyPercent > $1.accuracyPercent }
        case .speed:
            models.sort { $0.speedPercent > $1.speedPercent }
        }

        return models
    }

    func activateSpeechModel(_ model: SettingsStore.SpeechModel) {
        guard !self.areSpeechModelActionsBlocked,
              SettingsStore.SpeechModel.availableModels.contains(model)
        else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            self.settings.selectedSpeechModel = model
            self.previewSpeechModel = model
            self.setSelectedSpeechProvider(model.provider)
        }
        self.asr.resetTranscriptionProvider()
        if model.isCloudSpeechModel {
            self.refreshSonioxCredentialState()
            return
        }
        Task {
            do {
                try await self.asr.ensureAsrReady()
            } catch is CancellationError {
                DebugLogger.shared.info("Model activation cancelled: \(model.displayName)", source: "AISettingsView")
            } catch {
                DebugLogger.shared.error("Failed to prepare model after activation: \(error)", source: "AISettingsView")
                self.asr.errorTitle = "Model Activation Failed"
                self.asr.errorMessage = error.localizedDescription
                self.asr.showError = true
            }
        }
    }

    func downloadSpeechModel(_ model: SettingsStore.SpeechModel) {
        guard !self.areSpeechModelActionsBlocked else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.asr.downloadModel(model, progressHandler: nil)
                DebugLogger.shared.info("Model download completed: \(model.displayName)", source: "VoiceEngineVM")
            } catch is CancellationError {
                DebugLogger.shared.info("Model download cancelled: \(model.displayName)", source: "VoiceEngineVM")
            } catch {
                DebugLogger.shared.error("Failed to download model \(model.displayName): \(error)", source: "VoiceEngineVM")
                self.asr.errorTitle = "Model Download Failed"
                self.asr.errorMessage = error.localizedDescription
                self.asr.showError = true
            }
        }
    }

    func cancelSpeechModelDownload() {
        guard self.downloadingModel != nil, !self.isCancellingModelDownload else { return }
        self.asr.cancelModelDownload()
    }

    func cancelActiveModelPreparation() {
        self.asr.cancelModelPreparation()
    }

    func deleteSpeechModel(_ model: SettingsStore.SpeechModel) {
        guard !self.areSpeechModelActionsBlocked else { return }
        let previousActive = self.settings.selectedSpeechModel

        Task {
            let shouldRestore = previousActive != model
            await MainActor.run {
                if shouldRestore {
                    self.suppressSpeechProviderSync = true
                }
                self.settings.selectedSpeechModel = model
                self.asr.resetTranscriptionProvider()
            }

            defer {
                Task { @MainActor in
                    guard shouldRestore else { return }
                    self.skipNextSpeechModelSync = true
                    self.settings.selectedSpeechModel = previousActive
                    self.asr.resetTranscriptionProvider()
                    if self.previewSpeechModel == model {
                        self.previewSpeechModel = model
                    }
                    self.suppressSpeechProviderSync = false
                }
            }

            await self.deleteModels()
        }
    }

    func isActiveSpeechModel(_ model: SettingsStore.SpeechModel) -> Bool {
        self.settings.selectedSpeechModel == model
    }

    var modelDescriptionText: String {
        let model = self.settings.selectedSpeechModel
        switch model {
        case .appleSpeech:
            return "Apple Speech (Legacy) uses built-in macOS speech recognition. No model download required, works on Intel and Apple Silicon."
        case .appleSpeechAnalyzer:
            return "Apple Speech uses advanced on-device recognition with fast, accurate transcription. Requires macOS 26+."
        case .parakeetTDT:
            return "Parakeet TDT v3 uses CoreML and Neural Engine for fastest transcription (25 languages) on Apple Silicon."
        case .parakeetTDTv2:
            return "Parakeet TDT v2 is an English-only model optimized for accuracy and consistency on Apple Silicon."
        case .parakeetRealtime:
            return "Parakeet Flash uses FluidAudio's true streaming EOU pipeline for low-latency English dictation. Best when you want words to appear live as you speak."
        case .qwen3Asr:
            return "Qwen3 ASR is a multilingual FluidAudio model with strong quality, but higher memory usage. Requires macOS 15+."
        case .cohereTranscribeSixBit:
            return "Cohere Transcribe downloads a CoreML pipeline from Hugging Face and caches it locally. Select the language manually before dictation. Best on Apple Silicon with 8GB+ RAM."
        case .nemotronOffline:
            return "Nemotron 3.5 Multilingual is slower but more accurate. Supports around 40 languages with auto or manual language selection. Best on Apple Silicon with 8GB+ RAM."
        case .nemotronStreaming, .nemotronStreaming320:
            return "Nemotron Speech 3.5 Streaming Capable uses NVIDIA's streaming CoreML pipeline. Supports around 40 languages with auto or manual language selection."
        case .sonioxV5:
            return "Soniox v5 Realtime streams dictation through Soniox with automatic language detection or an input-language hint."
        default:
            return "Whisper models support 99 languages and work on any Mac."
        }
    }

    func downloadModels() async {
        do {
            try await self.asr.ensureAsrReady()
        } catch is CancellationError {
            DebugLogger.shared.info("Model download cancelled", source: "AISettingsView")
        } catch {
            DebugLogger.shared.error("Failed to download models: \(error)", source: "AISettingsView")
            self.asr.errorTitle = "Model Download Failed"
            self.asr.errorMessage = error.localizedDescription
            self.asr.showError = true
        }
    }

    func deleteModels() async {
        do {
            try await self.asr.clearModelCache()
            let model = self.settings.selectedSpeechModel
            if model.requiresExternalArtifacts {
                self.settings.setExternalCoreMLArtifactsDirectory(nil, for: model)
                self.asr.resetTranscriptionProvider()
            }
        } catch {
            DebugLogger.shared.error("Failed to delete models: \(error)", source: "AISettingsView")
        }
    }

    func setSelectedSpeechProvider(_ provider: SettingsStore.SpeechModel.Provider) {
        self.selectedSpeechProvider = provider
    }

    func openExternalModelSource(for model: SettingsStore.SpeechModel) {
        guard let url = model.externalCoreMLSpec?.sourceURL else { return }
        NSWorkspace.shared.open(url)
    }
}

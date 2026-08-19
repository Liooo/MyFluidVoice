import Foundation

nonisolated struct RecordingSessionID: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct RecordingSpeechConfiguration: Equatable {
    let inputSourceID: String?
    let localeIdentifier: String
    let model: SettingsStore.SpeechModel
    let languageBinding: VoiceEngineLanguageRoute.LanguageBinding

    init?(
        inputSourceID: String?,
        localeIdentifier: String,
        model: SettingsStore.SpeechModel,
        languageBinding: VoiceEngineLanguageRoute.LanguageBinding
    ) {
        guard Self.isCompatible(model: model, languageBinding: languageBinding) else {
            return nil
        }
        if case let .appleSpeech(bindingLocaleIdentifier) = languageBinding,
           Self.normalizedLocaleIdentifier(bindingLocaleIdentifier) !=
           Self.normalizedLocaleIdentifier(localeIdentifier)
        {
            return nil
        }

        self.inputSourceID = inputSourceID
        self.localeIdentifier = localeIdentifier
        self.model = model
        self.languageBinding = languageBinding
    }

    private static func normalizedLocaleIdentifier(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func isCompatible(
        model: SettingsStore.SpeechModel,
        languageBinding: VoiceEngineLanguageRoute.LanguageBinding
    ) -> Bool {
        switch (model, languageBinding) {
        case (.appleSpeech, .appleSpeech),
             (.appleSpeechAnalyzer, .appleSpeech),
             (.cohereTranscribeSixBit, .cohere),
             (.nemotronOffline, .nemotron),
             (.nemotronStreaming, .nemotron),
             (.nemotronStreaming320, .nemotron),
             (.sonioxV5, .soniox),
             (.whisperTiny, .whisper),
             (.whisperBase, .whisper),
             (.whisperSmall, .whisper),
             (.whisperMedium, .whisper),
             (.whisperLargeTurbo, .whisper),
             (.whisperLarge, .whisper),
             (.parakeetTDT, .automatic),
             (.parakeetTDTv2, .automatic),
             (.parakeetRealtime, .automatic),
             (.qwen3Asr, .automatic):
            return true
        default:
            return false
        }
    }
}

/// Holds the latest speech configuration requested while an earlier provider
/// boundary is still being finalized. Intermediate requests can be skipped;
/// the newest configuration is the one that matches the current keyboard
/// input source and must be applied next.
struct RecordingSpeechConfigurationSwitchQueue {
    private(set) var pendingConfiguration: RecordingSpeechConfiguration?

    mutating func replace(with configuration: RecordingSpeechConfiguration) {
        self.pendingConfiguration = configuration
    }

    mutating func take() -> RecordingSpeechConfiguration? {
        defer { self.pendingConfiguration = nil }
        return self.pendingConfiguration
    }
}

enum DictationActivationStyle: Equatable {
    case toggle
    case pushToTalk
}

/// Joins transcript segments produced before and after an input-source change.
/// Speech providers commonly trim segment boundaries, so joining is centralized
/// here instead of letting each caller accidentally drop or duplicate text.
nonisolated enum DictationTranscriptComposer {
    static func combine(_ segments: [String]) -> String {
        segments.reduce(into: "") { result, segment in
            self.append(segment, to: &result)
        }
    }

    static func append(_ segment: String, to result: inout String) {
        let trimmedSegment = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSegment.isEmpty == false else { return }

        let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedResult.isEmpty == false else {
            result = trimmedSegment
            return
        }

        let left = trimmedResult.last
        let right = trimmedSegment.first
        let hasSeparator = left?.isWhitespace == true || right?.isWhitespace == true
        let rightIsPunctuation = right?.isPunctuation == true
        let bothAreCJK = left.map(self.isCJK) == true && right.map(self.isCJK) == true
        let separator = hasSeparator || rightIsPunctuation || bothAreCJK ? "" : " "
        result = trimmedResult + separator + trimmedSegment
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, // Hiragana and Katakana
                 0x3400...0x4DBF, // CJK Extension A
                 0x4E00...0x9FFF, // CJK Unified Ideographs
                 0xAC00...0xD7AF, // Hangul syllables
                 0xF900...0xFAFF: // CJK compatibility ideographs
                return true
            default:
                return false
            }
        }
    }
}

final nonisolated class DictationDeliveryGate: @unchecked Sendable {
    private enum State: Equatable {
        case pending
        case committed
        case cancelled
    }

    private let lock = NSLock()
    private var state: State = .pending

    func commit() -> Bool {
        self.lock.withLock {
            guard self.state == .pending else { return false }
            self.state = .committed
            return true
        }
    }

    func cancel() -> Bool {
        self.lock.withLock {
            guard self.state == .pending else { return false }
            self.state = .cancelled
            return true
        }
    }

    var isCommitted: Bool {
        self.lock.withLock { self.state == .committed }
    }
}

enum DictationSessionState: Equatable {
    case capturing
    case finalizing
    case delivering
    case cancelled
    case completed
}

enum DictationExitAction: String, Codable, CaseIterable, Identifiable {
    case doNothing
    case discard
    case paste

    var id: String {
        self.rawValue
    }

    var displayName: String {
        switch self {
        case .doNothing: return "Do nothing"
        case .discard: return "Close and discard"
        case .paste: return "Close and paste"
        }
    }
}

enum DictationOutputOutcome: String, Codable, CaseIterable {
    case typed
    case copied
    case noTarget
    case discarded
}

@MainActor
final class DictationSessionCoordinator {
    struct Session: Equatable {
        let id: RecordingSessionID
        let activationStyle: DictationActivationStyle
        let speechConfiguration: RecordingSpeechConfiguration
        let exitPoliciesEnabled: Bool
    }

    private struct ActiveSession {
        var session: Session
        var state: DictationSessionState
        var outputOutcome: DictationOutputOutcome?
        var deliveryGate: DictationDeliveryGate?
    }

    enum ExitDisposition: Equatable {
        case ignore
        case finalize
        case discard
    }

    private var activeSession: ActiveSession?

    var currentSession: Session? {
        guard self.hasActiveSession else { return nil }
        return self.activeSession?.session
    }

    var hasActiveSession: Bool {
        switch self.activeSession?.state {
        case .capturing, .finalizing, .delivering:
            return true
        case .cancelled, .completed, .none:
            return false
        }
    }

    @discardableResult
    func begin(
        activationStyle: DictationActivationStyle,
        speechConfiguration: RecordingSpeechConfiguration,
        exitPoliciesEnabled: Bool = true
    ) -> Session {
        let session = Session(
            id: RecordingSessionID(),
            activationStyle: activationStyle,
            speechConfiguration: speechConfiguration,
            exitPoliciesEnabled: exitPoliciesEnabled
        )
        self.activeSession = ActiveSession(
            session: session,
            state: .capturing,
            outputOutcome: nil,
            deliveryGate: nil
        )
        return session
    }

    func state(for id: RecordingSessionID) -> DictationSessionState? {
        guard let activeSession = self.activeSession,
              activeSession.session.id == id
        else { return nil }
        return activeSession.state
    }

    func outputOutcome(for id: RecordingSessionID) -> DictationOutputOutcome? {
        guard let activeSession = self.activeSession,
              activeSession.session.id == id
        else { return nil }
        return activeSession.outputOutcome
    }

    func isCapturing(_ id: RecordingSessionID) -> Bool {
        self.state(for: id) == .capturing
    }

    func canContinueFinalization(for id: RecordingSessionID) -> Bool {
        self.state(for: id) == .finalizing
    }

    @discardableResult
    func resolveActivationStyle(
        _ activationStyle: DictationActivationStyle,
        for id: RecordingSessionID
    ) -> Bool {
        guard var activeSession = self.activeSession,
              activeSession.session.id == id,
              activeSession.state == .capturing
        else { return false }

        activeSession.session = Session(
            id: activeSession.session.id,
            activationStyle: activationStyle,
            speechConfiguration: activeSession.session.speechConfiguration,
            exitPoliciesEnabled: activeSession.session.exitPoliciesEnabled
        )
        self.activeSession = activeSession
        return true
    }

    @discardableResult
    func updateSpeechConfiguration(
        _ speechConfiguration: RecordingSpeechConfiguration,
        for id: RecordingSessionID
    ) -> Bool {
        guard var activeSession = self.activeSession,
              activeSession.session.id == id,
              activeSession.state == .capturing
        else { return false }

        activeSession.session = Session(
            id: activeSession.session.id,
            activationStyle: activeSession.session.activationStyle,
            speechConfiguration: speechConfiguration,
            exitPoliciesEnabled: activeSession.session.exitPoliciesEnabled
        )
        self.activeSession = activeSession
        return true
    }

    @discardableResult
    func setExitPoliciesEnabled(
        _ isEnabled: Bool,
        for id: RecordingSessionID
    ) -> Bool {
        guard var activeSession = self.activeSession,
              activeSession.session.id == id,
              activeSession.state == .capturing
        else { return false }

        activeSession.session = Session(
            id: activeSession.session.id,
            activationStyle: activeSession.session.activationStyle,
            speechConfiguration: activeSession.session.speechConfiguration,
            exitPoliciesEnabled: isEnabled
        )
        self.activeSession = activeSession
        return true
    }

    @discardableResult
    func beginFinalization(for id: RecordingSessionID) -> Bool {
        guard var activeSession = self.activeSession,
              activeSession.session.id == id,
              activeSession.state == .capturing
        else { return false }

        activeSession.state = .finalizing
        self.activeSession = activeSession
        return true
    }

    @discardableResult
    func cancel(for id: RecordingSessionID) -> Bool {
        guard var activeSession = self.activeSession,
              activeSession.session.id == id,
              activeSession.state == .capturing || activeSession.state == .finalizing ||
              (activeSession.state == .delivering && activeSession.deliveryGate?.cancel() == true)
        else { return false }

        activeSession.state = .cancelled
        activeSession.outputOutcome = .discarded
        self.activeSession = activeSession
        return true
    }

    @discardableResult
    func claimOutputDelivery(for id: RecordingSessionID) -> Bool {
        self.claimOutputDeliveryGate(for: id) != nil
    }

    func claimOutputDeliveryGate(for id: RecordingSessionID) -> DictationDeliveryGate? {
        guard var activeSession = self.activeSession,
              activeSession.session.id == id,
              activeSession.state == .finalizing
        else { return nil }

        let deliveryGate = DictationDeliveryGate()
        activeSession.state = .delivering
        activeSession.deliveryGate = deliveryGate
        self.activeSession = activeSession
        return deliveryGate
    }

    @discardableResult
    func complete(
        for id: RecordingSessionID,
        outcome: DictationOutputOutcome = .typed
    ) -> Bool {
        guard var activeSession = self.activeSession,
              activeSession.session.id == id,
              activeSession.state == .delivering,
              activeSession.deliveryGate?.isCommitted == true
        else { return false }

        activeSession.state = .completed
        activeSession.outputOutcome = outcome
        self.activeSession = activeSession
        return true
    }

    @discardableResult
    func completeWithoutDelivery(for id: RecordingSessionID) -> Bool {
        guard var activeSession = self.activeSession,
              activeSession.session.id == id,
              activeSession.state == .finalizing
        else { return false }

        activeSession.state = .completed
        self.activeSession = activeSession
        return true
    }

    func requestExit(_ action: DictationExitAction, for id: RecordingSessionID) -> ExitDisposition {
        guard let activeSession = self.activeSession,
              activeSession.session.id == id,
              activeSession.session.activationStyle == .toggle,
              activeSession.session.exitPoliciesEnabled
        else { return .ignore }

        switch action {
        case .doNothing:
            return .ignore
        case .discard:
            return self.cancel(for: id) ? .discard : .ignore
        case .paste:
            return activeSession.state == .capturing ? .finalize : .ignore
        }
    }
}

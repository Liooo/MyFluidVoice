import Foundation

struct RecordingSessionID: Hashable {
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
}

enum DictationActivationStyle: Equatable {
    case toggle
    case pushToTalk
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

    var id: String { self.rawValue }

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
    }

    private struct ActiveSession {
        let session: Session
        var state: DictationSessionState
    }

    enum ExitDisposition: Equatable {
        case ignore
        case finalize
        case discard
    }

    private var activeSession: ActiveSession?

    var currentSession: Session? {
        self.activeSession?.session
    }

    @discardableResult
    func begin(
        activationStyle: DictationActivationStyle,
        speechConfiguration: RecordingSpeechConfiguration
    ) -> Session {
        let session = Session(
            id: RecordingSessionID(),
            activationStyle: activationStyle,
            speechConfiguration: speechConfiguration
        )
        self.activeSession = ActiveSession(session: session, state: .capturing)
        return session
    }

    func state(for id: RecordingSessionID) -> DictationSessionState? {
        guard let activeSession = self.activeSession,
              activeSession.session.id == id
        else { return nil }
        return activeSession.state
    }

    func isCapturing(_ id: RecordingSessionID) -> Bool {
        self.state(for: id) == .capturing
    }

    func canContinueFinalization(for id: RecordingSessionID) -> Bool {
        self.state(for: id) == .finalizing
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
              activeSession.state == .capturing || activeSession.state == .finalizing
        else { return false }

        activeSession.state = .cancelled
        self.activeSession = activeSession
        return true
    }

    @discardableResult
    func claimOutputDelivery(for id: RecordingSessionID) -> Bool {
        guard var activeSession = self.activeSession,
              activeSession.session.id == id,
              activeSession.state == .finalizing
        else { return false }

        activeSession.state = .delivering
        self.activeSession = activeSession
        return true
    }

    @discardableResult
    func complete(for id: RecordingSessionID) -> Bool {
        guard var activeSession = self.activeSession,
              activeSession.session.id == id,
              activeSession.state == .delivering
        else { return false }

        activeSession.state = .completed
        self.activeSession = activeSession
        return true
    }

    func requestExit(_ action: DictationExitAction, for id: RecordingSessionID) -> ExitDisposition {
        guard let activeSession = self.activeSession,
              activeSession.session.id == id,
              activeSession.session.activationStyle == .toggle
        else { return .ignore }

        switch action {
        case .doNothing:
            return .ignore
        case .discard:
            return self.cancel(for: id) ? .discard : .ignore
        case .paste:
            return self.beginFinalization(for: id) ? .finalize : .ignore
        }
    }
}

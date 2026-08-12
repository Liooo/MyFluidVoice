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
}

enum DictationActivationStyle: Equatable {
    case toggle
    case pushToTalk
}

enum DictationSessionState: Equatable {
    case capturing
    case finalizing
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
        fileprivate(set) var state: DictationSessionState
    }

    enum ExitDisposition: Equatable {
        case ignore
        case finalize
        case discard
    }

    private(set) var activeSession: Session?

    @discardableResult
    func begin(
        activationStyle: DictationActivationStyle,
        speechConfiguration: RecordingSpeechConfiguration
    ) -> Session {
        let session = Session(
            id: RecordingSessionID(),
            activationStyle: activationStyle,
            speechConfiguration: speechConfiguration,
            state: .capturing
        )
        self.activeSession = session
        return session
    }

    func isCurrent(_ id: RecordingSessionID) -> Bool {
        guard let session = self.activeSession, session.id == id else { return false }
        return session.state == .capturing || session.state == .finalizing
    }

    @discardableResult
    func beginFinalization(for id: RecordingSessionID) -> Bool {
        guard var session = self.activeSession,
              session.id == id,
              session.state == .capturing
        else { return false }

        session.state = .finalizing
        self.activeSession = session
        return true
    }

    @discardableResult
    func cancel(for id: RecordingSessionID) -> Bool {
        guard var session = self.activeSession,
              session.id == id,
              session.state == .capturing || session.state == .finalizing
        else { return false }

        session.state = .cancelled
        self.activeSession = session
        return true
    }

    @discardableResult
    func complete(for id: RecordingSessionID) -> Bool {
        guard var session = self.activeSession,
              session.id == id,
              session.state == .finalizing
        else { return false }

        session.state = .completed
        self.activeSession = session
        return true
    }

    func requestExit(_ action: DictationExitAction, for id: RecordingSessionID) -> ExitDisposition {
        guard let session = self.activeSession,
              session.id == id,
              session.activationStyle == .toggle
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

import Foundation

/// Pure state machine used by shortcut recording to distinguish a single modifier shortcut from
/// a clean double tap without accepting mixed modifier families or opposite physical key sides.
nonisolated struct ShortcutModifierTapCaptureDecision: Equatable {
    static let interval = DoubleModifierTapDecision.interval

    nonisolated enum Event: Equatable {
        case flagsChanged(
            keyCode: UInt16,
            pressedModifierKeyCodes: Set<UInt16>,
            timestamp: TimeInterval
        )
        case deadline(timestamp: TimeInterval)
        case interrupt
        case reset
    }

    nonisolated enum Outcome: Equatable {
        case handled
        case observeChord
        case cancelCandidateAndObserveChord
        case waitForSecondPress(deadline: TimeInterval)
        case recordSingle(keyCode: UInt16)
        case recordDouble(keyCode: UInt16)
    }

    nonisolated struct State: Equatable {
        fileprivate nonisolated enum Phase: Equatable {
            case idle
            case firstPress(keyCode: UInt16, timestamp: TimeInterval)
            case waitingForSecondPress(keyCode: UInt16, deadline: TimeInterval)
            case secondPress(keyCode: UInt16)
        }

        fileprivate var phase: Phase = .idle

        init() {}

        fileprivate init(phase: Phase) {
            self.phase = phase
        }
    }

    let state: State
    let outcome: Outcome

    static func evaluate(event: Event, state: State) -> Self {
        switch event {
        case .reset, .interrupt:
            return .init(state: .init(), outcome: .handled)
        case let .deadline(timestamp):
            return self.evaluateDeadline(timestamp: timestamp, state: state)
        case let .flagsChanged(keyCode, pressedModifierKeyCodes, timestamp):
            return self.evaluateFlagsChanged(
                keyCode: keyCode,
                pressedModifierKeyCodes: pressedModifierKeyCodes,
                timestamp: timestamp,
                state: state
            )
        }
    }

    private static func evaluateDeadline(timestamp: TimeInterval, state: State) -> Self {
        guard case let .waitingForSecondPress(keyCode, deadline) = state.phase else {
            return .init(state: state, outcome: .handled)
        }
        guard timestamp >= deadline else {
            return .init(state: state, outcome: .handled)
        }
        return .init(state: .init(), outcome: .recordSingle(keyCode: keyCode))
    }

    private static func evaluateFlagsChanged(
        keyCode: UInt16,
        pressedModifierKeyCodes: Set<UInt16>,
        timestamp: TimeInterval,
        state: State
    ) -> Self {
        switch state.phase {
        case .idle:
            guard HotkeyShortcut.modifierFlag(forKeyCode: keyCode) != nil,
                  pressedModifierKeyCodes == [keyCode]
            else {
                return .init(state: .init(), outcome: .observeChord)
            }
            return .init(
                state: .init(phase: .firstPress(keyCode: keyCode, timestamp: timestamp)),
                outcome: .observeChord
            )

        case let .firstPress(ownerKeyCode, firstPressTimestamp):
            if keyCode == ownerKeyCode, pressedModifierKeyCodes == [ownerKeyCode] {
                return .init(state: state, outcome: .observeChord)
            }
            if keyCode == ownerKeyCode, pressedModifierKeyCodes.isEmpty {
                let deadline = firstPressTimestamp + self.interval
                guard timestamp < deadline else {
                    return .init(state: .init(), outcome: .recordSingle(keyCode: ownerKeyCode))
                }
                return .init(
                    state: .init(phase: .waitingForSecondPress(keyCode: ownerKeyCode, deadline: deadline)),
                    outcome: .waitForSecondPress(deadline: deadline)
                )
            }
            return .init(state: .init(), outcome: .cancelCandidateAndObserveChord)

        case let .waitingForSecondPress(ownerKeyCode, deadline):
            guard timestamp < deadline else {
                return .init(state: .init(), outcome: .recordSingle(keyCode: ownerKeyCode))
            }
            if keyCode == ownerKeyCode, pressedModifierKeyCodes == [ownerKeyCode] {
                return .init(
                    state: .init(phase: .secondPress(keyCode: ownerKeyCode)),
                    outcome: .handled
                )
            }
            if pressedModifierKeyCodes.isEmpty {
                return .init(state: state, outcome: .handled)
            }
            return .init(state: .init(), outcome: .cancelCandidateAndObserveChord)

        case let .secondPress(ownerKeyCode):
            if keyCode == ownerKeyCode, pressedModifierKeyCodes == [ownerKeyCode] {
                return .init(state: state, outcome: .handled)
            }
            if keyCode == ownerKeyCode, pressedModifierKeyCodes.isEmpty {
                return .init(state: .init(), outcome: .recordDouble(keyCode: ownerKeyCode))
            }
            return .init(state: .init(), outcome: .cancelCandidateAndObserveChord)
        }
    }
}

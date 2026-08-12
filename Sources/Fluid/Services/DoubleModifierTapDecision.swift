import Foundation

/// Pure transition for recognizing a modifier-only double tap. The caller supplies timestamps and
/// currently pressed physical modifier key codes, keeping timing and event-tap plumbing out of the
/// decision itself.
nonisolated struct DoubleModifierTapDecision: Equatable {
    static let interval: TimeInterval = 0.300

    nonisolated enum Event: Equatable {
        case modifierFlagsChanged(
            keyCode: UInt16,
            pressedModifierKeyCodes: Set<UInt16>,
            isRepeat: Bool,
            timestamp: TimeInterval
        )
        case interrupt(pressedModifierKeyCodes: Set<UInt16>)
        case reset
    }

    nonisolated enum Outcome: Equatable {
        case ignore
        case handled
        case secondPress
        case secondRelease
    }

    nonisolated struct State: Equatable {
        fileprivate nonisolated enum Phase: Equatable {
            case idle
            case firstPress(Owner)
            case waitingForSecondPress(Owner, firstReleaseTimestamp: TimeInterval)
            case secondPress(Owner)
            case canceledUntilModifiersReleased(Owner)
        }

        fileprivate nonisolated struct Owner: Equatable {
            let shortcut: HotkeyShortcut
            let holdModeType: HotkeyHoldModeType
            let physicalKeyCode: UInt16
        }

        fileprivate var phase: Phase = .idle

        init() {}

        fileprivate init(phase: Phase) {
            self.phase = phase
        }
    }

    let state: State
    let outcome: Outcome

    static func evaluate(
        shortcut: HotkeyShortcut,
        holdModeType: HotkeyHoldModeType,
        event: Event,
        state: State
    ) -> DoubleModifierTapDecision {
        switch event {
        case .reset:
            return self.reset(state: state)

        case let .interrupt(pressedModifierKeyCodes):
            return self.interrupt(
                pressedModifierKeyCodes: pressedModifierKeyCodes,
                state: state
            )

        case let .modifierFlagsChanged(keyCode, pressedModifierKeyCodes, isRepeat, timestamp):
            return self.evaluateFlagsChanged(
                shortcut: shortcut,
                holdModeType: holdModeType,
                keyCode: keyCode,
                pressedModifierKeyCodes: pressedModifierKeyCodes,
                isRepeat: isRepeat,
                timestamp: timestamp,
                state: state
            )
        }
    }

    static func interrupt(
        pressedModifierKeyCodes: Set<UInt16>,
        state: State
    ) -> DoubleModifierTapDecision {
        if case .secondPress = state.phase {
            return .init(state: state, outcome: .ignore)
        }

        let owner: State.Owner?
        switch state.phase {
        case let .firstPress(currentOwner),
             let .waitingForSecondPress(currentOwner, _),
             let .canceledUntilModifiersReleased(currentOwner):
            owner = currentOwner
        case .idle, .secondPress:
            owner = nil
        }

        guard let owner else { return .init(state: State(), outcome: .ignore) }
        let phase: State.Phase = pressedModifierKeyCodes.isEmpty
            ? .idle
            : .canceledUntilModifiersReleased(owner)
        return .init(state: State(phase: phase), outcome: .ignore)
    }

    static func reset(state _: State) -> DoubleModifierTapDecision {
        .init(state: State(), outcome: .ignore)
    }

    private static func evaluateFlagsChanged(
        shortcut: HotkeyShortcut,
        holdModeType: HotkeyHoldModeType,
        keyCode: UInt16,
        pressedModifierKeyCodes: Set<UInt16>,
        isRepeat: Bool,
        timestamp: TimeInterval,
        state: State
    ) -> DoubleModifierTapDecision {
        var phase = state.phase
        if case let .waitingForSecondPress(_, firstReleaseTimestamp) = phase,
           timestamp - firstReleaseTimestamp > self.interval
        {
            phase = .idle
        }

        if case let .canceledUntilModifiersReleased(owner) = phase {
            let nextPhase: State.Phase = pressedModifierKeyCodes.isEmpty
                ? .idle
                : .canceledUntilModifiersReleased(owner)
            let changedFlag = HotkeyShortcut.modifierFlag(forKeyCode: keyCode)
            let outcome: Outcome = changedFlag == owner.shortcut.modifierTriggerFlag ? .handled : .ignore
            return .init(state: State(phase: nextPhase), outcome: outcome)
        }

        if case let .secondPress(owner) = phase {
            guard self.isOwner(owner, shortcut: shortcut, holdModeType: holdModeType) else {
                return .init(state: State(phase: phase), outcome: .ignore)
            }
            guard keyCode == owner.physicalKeyCode else {
                return .init(state: State(phase: phase), outcome: .ignore)
            }
            if pressedModifierKeyCodes.contains(keyCode) {
                return .init(state: State(phase: phase), outcome: .handled)
            }
            return .init(state: State(), outcome: .secondRelease)
        }

        if case let .firstPress(owner) = phase {
            guard self.isOwner(owner, shortcut: shortcut, holdModeType: holdModeType) else {
                return .init(state: State(phase: phase), outcome: .ignore)
            }
            guard keyCode == owner.physicalKeyCode else {
                return .init(state: State(phase: .canceledUntilModifiersReleased(owner)), outcome: .ignore)
            }
            if pressedModifierKeyCodes == [keyCode], !isRepeat {
                return .init(state: State(phase: phase), outcome: .handled)
            }
            if pressedModifierKeyCodes.contains(keyCode) {
                return .init(state: State(phase: .canceledUntilModifiersReleased(owner)), outcome: .handled)
            }
            if !pressedModifierKeyCodes.isEmpty {
                return .init(state: State(phase: .canceledUntilModifiersReleased(owner)), outcome: .handled)
            }
            return .init(
                state: State(phase: .waitingForSecondPress(owner, firstReleaseTimestamp: timestamp)),
                outcome: .handled
            )
        }

        if case let .waitingForSecondPress(owner, firstReleaseTimestamp) = phase {
            guard self.isOwner(owner, shortcut: shortcut, holdModeType: holdModeType) else {
                return .init(state: State(phase: phase), outcome: .ignore)
            }
            guard let changedFlag = HotkeyShortcut.modifierFlag(forKeyCode: keyCode),
                  changedFlag == shortcut.modifierTriggerFlag
            else {
                let nextPhase: State.Phase = pressedModifierKeyCodes.isEmpty
                    ? .idle
                    : .canceledUntilModifiersReleased(owner)
                return .init(state: State(phase: nextPhase), outcome: .ignore)
            }
            guard pressedModifierKeyCodes.contains(keyCode) else {
                return .init(
                    state: State(phase: .waitingForSecondPress(owner, firstReleaseTimestamp: firstReleaseTimestamp)),
                    outcome: .handled
                )
            }
            guard !isRepeat,
                  keyCode == owner.physicalKeyCode,
                  pressedModifierKeyCodes == [keyCode]
            else {
                return .init(state: State(phase: .canceledUntilModifiersReleased(owner)), outcome: .handled)
            }
            return .init(state: State(phase: .secondPress(owner)), outcome: .secondPress)
        }

        guard shortcut.isDoubleModifierShortcut,
              !isRepeat,
              let changedFlag = HotkeyShortcut.modifierFlag(forKeyCode: keyCode),
              changedFlag == shortcut.modifierTriggerFlag,
              pressedModifierKeyCodes == [keyCode]
        else {
            return .init(state: State(), outcome: .ignore)
        }

        let owner = State.Owner(
            shortcut: shortcut,
            holdModeType: holdModeType,
            physicalKeyCode: keyCode
        )
        return .init(state: State(phase: .firstPress(owner)), outcome: .handled)
    }

    private static func isOwner(
        _ owner: State.Owner,
        shortcut: HotkeyShortcut,
        holdModeType: HotkeyHoldModeType
    ) -> Bool {
        owner.shortcut == shortcut && owner.holdModeType == holdModeType
    }
}

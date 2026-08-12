import Foundation

enum DictationOutputTarget: Equatable {
    case inAppEditor
    case writableExternal
    case unavailable
}

struct DictationOutputRoutingDecision: Equatable {
    let shouldTypeExternally: Bool
    let shouldCopyToClipboard: Bool
    let outcome: DictationOutputOutcome?

    static func resolve(
        shouldPersistOutputs: Bool,
        target: DictationOutputTarget,
        alwaysCopyToClipboard: Bool,
        copyWhenNoWritableInputFocused: Bool
    ) -> DictationOutputRoutingDecision {
        guard shouldPersistOutputs else {
            return .init(
                shouldTypeExternally: false,
                shouldCopyToClipboard: false,
                outcome: nil
            )
        }

        switch target {
        case .inAppEditor:
            return .init(
                shouldTypeExternally: false,
                shouldCopyToClipboard: false,
                outcome: .typed
            )
        case .writableExternal:
            return .init(
                shouldTypeExternally: true,
                shouldCopyToClipboard: alwaysCopyToClipboard,
                outcome: .typed
            )
        case .unavailable:
            let shouldCopy = alwaysCopyToClipboard || copyWhenNoWritableInputFocused
            return .init(
                shouldTypeExternally: false,
                shouldCopyToClipboard: shouldCopy,
                outcome: shouldCopy ? .copied : .noTarget
            )
        }
    }
}

struct FocusedInputAssessment: Equatable {
    let role: String?
    let subrole: String?
    let isEnabled: Bool
    let isEditable: Bool?
    let isValueSettable: Bool
    let isSelectedTextSettable: Bool
    let isSecureInputEnabled: Bool

    var isWritable: Bool {
        guard self.isEnabled, !self.isSecureInputEnabled else { return false }
        guard !Self.secureRoles.contains(self.role ?? ""),
              !Self.secureRoles.contains(self.subrole ?? "")
        else { return false }

        if self.isValueSettable || self.isSelectedTextSettable {
            return true
        }

        if self.isEditable == false {
            return false
        }

        if self.isEditable == true {
            return true
        }

        return Self.inherentlyWritableRoles.contains(self.role ?? "")
    }

    private static let secureRoles: Set<String> = [
        "AXSecureTextField",
        "AXSecureTextArea",
    ]

    private static let inherentlyWritableRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXSearchField",
        "AXComboBox",
    ]
}

import AppKit

/// Keeps the physical modifier-key set stable across duplicate `flagsChanged` events while still
/// distinguishing left and right keys when both sides of one modifier family are involved.
nonisolated enum PressedModifierKeyCodesDecision {
    static func synchronize(
        previous: Set<UInt16>,
        changedKeyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        changedKeyIsPhysicallyPressed: Bool
    ) -> Set<UInt16> {
        guard let changedFlag = HotkeyShortcut.modifierFlag(forKeyCode: changedKeyCode) else {
            return previous
        }

        let activeModifiers = modifiers.intersection(HotkeyShortcut.relevantModifierMask)
        let modifierGroups: [(NSEvent.ModifierFlags, [UInt16])] = [
            (.function, [63]),
            (.command, [55, 54]),
            (.option, [58, 61]),
            (.control, [59, 62]),
            (.shift, [56, 60]),
        ]
        var synchronized = previous.filter { keyCode in
            guard let flag = HotkeyShortcut.modifierFlag(forKeyCode: keyCode) else { return false }
            return activeModifiers.contains(flag)
        }

        guard let changedGroup = modifierGroups.first(where: { $0.0 == changedFlag }) else {
            return synchronized
        }
        guard activeModifiers.contains(changedFlag) else {
            synchronized.subtract(changedGroup.1)
            return synchronized
        }

        if synchronized.contains(changedKeyCode) {
            let siblingIsTracked = changedGroup.1.contains { keyCode in
                keyCode != changedKeyCode && synchronized.contains(keyCode)
            }
            if siblingIsTracked, !changedKeyIsPhysicallyPressed {
                synchronized.remove(changedKeyCode)
            }
        } else {
            // The current flagsChanged event is authoritative for an ordinary press. The
            // session-wide keyState query can still describe the previous event at this point.
            synchronized.insert(changedKeyCode)
        }

        return synchronized
    }
}

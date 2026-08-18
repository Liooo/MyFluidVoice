import CoreGraphics
import Foundation

/// A data-only window description used to distinguish clicks on this app's UI from outside clicks.
nonisolated struct ApplicationWindowSnapshot: Equatable {
    let ownerPID: pid_t
    let bounds: CGRect
    let isOnScreen: Bool
    let alpha: Double
}

nonisolated enum AppOwnedClickClassifier {
    /// `CGEvent.location` and `kCGWindowBounds` use the same global Quartz coordinate space.
    static func isInsideVisibleApplicationUI(
        _ point: CGPoint,
        applicationPID: pid_t,
        windows: [ApplicationWindowSnapshot]
    ) -> Bool {
        let frontmostWindowAtPoint = windows.first { window in
            window.isOnScreen
                && window.alpha > 0
                && !window.bounds.isEmpty
                && window.bounds.contains(point)
        }
        return frontmostWindowAtPoint?.ownerPID == applicationPID
    }

    /// Includes every on-screen window layer owned by the process, which covers panels and most
    /// transient application menus in addition to regular `NSWindow` instances.
    static func isInsideCurrentApplicationUI(_ point: CGPoint) -> Bool {
        self.isInsideVisibleApplicationUI(
            point,
            applicationPID: ProcessInfo.processInfo.processIdentifier,
            windows: self.currentWindowSnapshots()
        )
    }

    private static func currentWindowSnapshots() -> [ApplicationWindowSnapshot] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        // Core Graphics returns windows from front to back; preserve that order for hit testing.
        return windowInfo.compactMap { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else {
                return nil
            }

            return ApplicationWindowSnapshot(
                ownerPID: ownerPID,
                bounds: bounds,
                isOnScreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true,
                alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            )
        }
    }
}

import CoreGraphics
@testable import FluidVoice_Debug
import XCTest

final class OutsideClickMonitorTests: XCTestCase {
    func testClickInsideVisibleWindowOwnedByApplicationIsNotOutside() {
        let windows = [
            ApplicationWindowSnapshot(
                ownerPID: 42,
                bounds: CGRect(x: 100, y: 200, width: 320, height: 180),
                isOnScreen: true,
                alpha: 1
            ),
        ]

        XCTAssertTrue(
            AppOwnedClickClassifier.isInsideVisibleApplicationUI(
                CGPoint(x: 250, y: 275),
                applicationPID: 42,
                windows: windows
            )
        )
    }

    func testClickInsideOverlappingExternalWindowIsOutside() {
        let windows = [
            ApplicationWindowSnapshot(
                ownerPID: 99,
                bounds: CGRect(x: 0, y: 0, width: 500, height: 500),
                isOnScreen: true,
                alpha: 1
            ),
            ApplicationWindowSnapshot(
                ownerPID: 42,
                bounds: CGRect(x: 0, y: 0, width: 500, height: 500),
                isOnScreen: true,
                alpha: 1
            ),
        ]

        XCTAssertFalse(
            AppOwnedClickClassifier.isInsideVisibleApplicationUI(
                CGPoint(x: 250, y: 250),
                applicationPID: 42,
                windows: windows
            )
        )
    }

    func testClickOutsideEveryOwnedWindowIsOutside() {
        let windows = [
            ApplicationWindowSnapshot(
                ownerPID: 42,
                bounds: CGRect(x: 10, y: 10, width: 100, height: 100),
                isOnScreen: true,
                alpha: 1
            ),
            ApplicationWindowSnapshot(
                ownerPID: 42,
                bounds: CGRect(x: 200, y: 200, width: 100, height: 100),
                isOnScreen: true,
                alpha: 1
            ),
        ]

        XCTAssertFalse(
            AppOwnedClickClassifier.isInsideVisibleApplicationUI(
                CGPoint(x: 150, y: 150),
                applicationPID: 42,
                windows: windows
            )
        )
    }

    func testHiddenTransparentAndEmptyOwnedWindowsDoNotCountAsVisibleUI() {
        let click = CGPoint(x: 25, y: 25)
        let windows = [
            ApplicationWindowSnapshot(
                ownerPID: 42,
                bounds: CGRect(x: 0, y: 0, width: 50, height: 50),
                isOnScreen: false,
                alpha: 1
            ),
            ApplicationWindowSnapshot(
                ownerPID: 42,
                bounds: CGRect(x: 0, y: 0, width: 50, height: 50),
                isOnScreen: true,
                alpha: 0
            ),
            ApplicationWindowSnapshot(
                ownerPID: 42,
                bounds: CGRect(x: 25, y: 25, width: 0, height: 0),
                isOnScreen: true,
                alpha: 1
            ),
        ]

        XCTAssertFalse(
            AppOwnedClickClassifier.isInsideVisibleApplicationUI(
                click,
                applicationPID: 42,
                windows: windows
            )
        )
    }

    func testAnyVisibleOwnedWindowCanCountIncludingTransientPanelBounds() {
        let windows = [
            ApplicationWindowSnapshot(
                ownerPID: 42,
                bounds: CGRect(x: 600, y: 20, width: 180, height: 240),
                isOnScreen: true,
                alpha: 0.95
            ),
        ]

        XCTAssertTrue(
            AppOwnedClickClassifier.isInsideVisibleApplicationUI(
                CGPoint(x: 700, y: 100),
                applicationPID: 42,
                windows: windows
            )
        )
    }
}

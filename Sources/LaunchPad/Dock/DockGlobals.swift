import AppKit
import LaunchPadPrivate

/// Dock's global state that the Launchpad classes read (REF-ARCH-010). Here it holds what a separate
/// app can know (REF-DEV-005, REF-DEV-006, REF-DEV-007, REF-DEV-009).
@MainActor
@objc(DockGlobals)
final class DockGlobals: NSObject {
    /// The preference `slow-motion-allowed`, read once when the object is created; NO when unset
    /// (REF-OVERLAY-008). Read from this process's preferences (REF-DEV-002).
    @objc let slowMotionAllowed: Bool
    /// Whether another app's menu is being tracked, kept from the HIToolbox menu-tracking
    /// notifications as Dock keeps it (REF-DEV-009).
    @objc private(set) var externalMenuIsUp = false

    override init() {
        slowMotionAllowed = UserDefaults.standard.bool(forKey: "slow-motion-allowed")
        super.init()
        let connection = CGSMainConnectionID()
        // CoreCursorSet takes effect for a process that is not frontmost only with this connection
        // property (REF-DEV-006).
        CGSSetConnectionProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Notification.Name("com.apple.HIToolbox.beginMenuTrackingNotification"),
                           object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { dockGlobals.externalMenuIsUp = true }
        }
        center.addObserver(forName: Notification.Name("com.apple.HIToolbox.endMenuTrackingNotification"),
                           object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { dockGlobals.externalMenuIsUp = false }
        }
    }

    /// The process's window-server connection.
    @objc var dockConnection: UInt32 {
        UInt32(bitPattern: CGSMainConnectionID())
    }

    /// The system's Reduce Motion setting, as Dock's accessibility monitor reads it.
    @objc var axReduceMotion: Bool {
        _AXInterfaceGetReduceMotionEnabled()
    }

    /// Dock's split-view window picker. No outside counterpart (REF-DEV-007).
    @objc var inAcceleratedTwoUp: Bool { false }

    /// Dock's tile reordering in full screen. No outside counterpart (REF-DEV-007).
    @objc var reorderingTilesInFullscreen: Bool { false }
}

@MainActor let dockGlobals = DockGlobals()

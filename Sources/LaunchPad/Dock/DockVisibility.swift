import AppKit
import LaunchPadPrivate

/// Whether the Dock is shown (REF-ARCH-010). Dock keeps an override that shows an auto-hidden Dock
/// while Launchpad is open; a separate app can only turn auto-hide off and on again (REF-DEV-004).
@MainActor
@objc(DockVisibility)
final class DockVisibility: NSObject {
    var showOverrideFlags: UInt64 = 0

    /// Set in this process's preferences while auto-hide is turned off by `-setOverrideShowType:`, so
    /// that a launch after an exit while open turns it back on (REF-DEV-004).
    static let autoHideTurnedOffKey = "LaunchPadTurnedOffDockAutoHide"

    @objc(initWithSpaces:)
    init(spaces: Spaces) {
        super.init()
        if UserDefaults.standard.bool(forKey: Self.autoHideTurnedOffKey) {
            CoreDockSetAutoHideEnabled(true)
            UserDefaults.standard.removeObject(forKey: Self.autoHideTurnedOffKey)
        }
    }

    @objc(setOverrideShowType:)
    func setOverrideShowType(_ type: UInt64) {
        showOverrideFlags |= type
        if CoreDockGetAutoHideEnabled() {
            UserDefaults.standard.set(true, forKey: Self.autoHideTurnedOffKey)
            CoreDockSetAutoHideEnabled(false)
        }
    }

    @objc(removeOverrideShowType:)
    func removeOverrideShowType(_ type: UInt64) {
        showOverrideFlags &= ~type
        if showOverrideFlags == 0, UserDefaults.standard.bool(forKey: Self.autoHideTurnedOffKey) {
            CoreDockSetAutoHideEnabled(true)
            UserDefaults.standard.removeObject(forKey: Self.autoHideTurnedOffKey)
        }
    }
}

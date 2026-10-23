import AppKit
import LaunchPadPrivate

/// Whether the Dock is shown (REF-ARCH-010). Dock keeps an override that shows the Dock while
/// Launchpad is open, also where it would hide it (auto-hide, a full-screen app's space). A separate
/// app reaches an override of the same controller through the Dock's tile-size message: the Dock shows
/// itself while a size change is unfinished (REF-DEV-004).
@MainActor
@objc(DockVisibility)
final class DockVisibility: NSObject {
    var showOverrideFlags: UInt64 = 0

    /// Set in this process's preferences while the Dock's override is on, so that a launch after an
    /// exit while open removes it (REF-DEV-004).
    static let dockOverrideKey = "LaunchPadShowsDock"

    @objc(initWithSpaces:)
    init(spaces: Spaces) {
        super.init()
        if UserDefaults.standard.bool(forKey: Self.dockOverrideKey) {
            Self.finishSizeChange()
        }
    }

    @objc(setOverrideShowType:)
    func setOverrideShowType(_ type: UInt64) {
        showOverrideFlags |= type
        UserDefaults.standard.set(true, forKey: Self.dockOverrideKey)
        // REF-DEV-004: an unfinished change to the size the Dock has.
        CoreDockSetTileSize(CoreDockGetTileSize(), 0)
    }

    @objc(removeOverrideShowType:)
    func removeOverrideShowType(_ type: UInt64) {
        showOverrideFlags &= ~type
        if showOverrideFlags == 0, UserDefaults.standard.bool(forKey: Self.dockOverrideKey) {
            Self.finishSizeChange()
        }
    }

    /// Finishes the size change, which removes the Dock's override and writes the unchanged size into
    /// the Dock's preferences. A finished change sets the override when the Dock has none (it was
    /// restarted), so an unfinished one goes first (REF-DEV-004).
    static func finishSizeChange() {
        let size = CoreDockGetTileSize()
        CoreDockSetTileSize(size, 0)
        CoreDockSetTileSize(size, 1)
        UserDefaults.standard.removeObject(forKey: dockOverrideKey)
    }
}

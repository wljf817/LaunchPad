import AppKit
import LaunchPadPrivate

/// A window on screen. The original wraps one window-server window it creates through SkyLight
/// (REF-ARCH-008); here the windows are AppKit's (app-architecture: Dock-specific replacement).
/// Launchpad's window is two `LaunchPadWindow`s: the main window below the Dock and the strip over
/// the menu bar (REF-DEV-003). `WALayerKitWindow` creates them.
@MainActor
@objc(WAWindow)
class WAWindow: NSObject {
    /// The main window: the display below the menu bar, under the Dock (REF-DEV-003).
    var mainWindow: LaunchPadWindow?
    /// The strip over the menu bar. Its window number is `-wid`, so the original's level changes on
    /// `-wid` raise and lower the part of the overlay that covers the menu bar (REF-DEV-003).
    var stripWindow: LaunchPadWindow?
    /// The window's frame in global coordinates (origin at the top left of the main display).
    var _frame: CGRect = .zero

    @objc func wid() -> UInt32 {
        UInt32(stripWindow?.windowNumber ?? 0)
    }

    @objc func frame() -> CGRect {
        _frame
    }

    /// Orders both windows in (`order` non-zero) or out (0) in `transaction`, as the original orders
    /// its window. A SkyLight transaction cannot show a window AppKit has never ordered in, so the
    /// first order-in goes through AppKit; AppKit then keeps both windows as visible (REF-DEV-014).
    @objc(orderImmediate:otherWindow:with:)
    func orderImmediate(_ order: Int32, otherWindow: UInt32, with transaction: OpaquePointer?) {
        if order != 0, mainWindow?.isVisible == false || stripWindow?.isVisible == false {
            mainWindow?.orderFrontRegardless()
            stripWindow?.orderFrontRegardless()
            return
        }
        guard let transaction else { return }
        let skyLightTransaction = Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(transaction)).takeUnretainedValue()
        let windows = order != 0 ? [mainWindow, stripWindow] : [stripWindow, mainWindow]
        for window in windows {
            guard let window else { continue }
            SLSTransactionOrderWindowGroup(skyLightTransaction, CGSWindowID(window.windowNumber), order, otherWindow)
        }
    }

    /// The original animates the window server's safe-aperture override to `value` frame by frame
    /// with Dock's own window animation machinery. The window server applies the override only for
    /// Dock's connection (REF-DEV-011), so the value is written once.
    @objc(setSafeApertureOverride:force:)
    class func setSafeApertureOverride(_ value: Double, force: Bool) {
        guard let transaction = SLSTransactionCreate(CGSMainConnectionID()) else { return }
        SLSTransactionSetSafeApertureOverride(transaction, value)
        SLSTransactionCommit(transaction, 0)
    }
}

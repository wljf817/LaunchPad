import CoreGraphics
import Foundation
import LaunchPadPrivate
import os

// Dock's display reconfiguration callback and the block it dispatches to the main queue
// (REF-OVERLAY-012). In the original they are functions of Dock's, not methods of a class. The rest
// of what the original's block does (Mission Control, Notification Center, `Spaces`, the hot
// corners) belongs to the Dock, which gets the same callback.

/// Set by a change's begin flag until the change's first result closes Launchpad (REF-OVERLAY-012).
@MainActor var displayReconfigurationPending = false

/// Dock's started flag: set once at startup, right before the controller is activated; until then a
/// display change is only noted (REF-OVERLAY-012).
@MainActor var dockStarted = false

/// Registers the callback, as Dock does at startup (REF-OVERLAY-012).
func registerDisplayReconfigurationCallback() {
    CGSDisplayRegisterReconfigurationCallbackWithUUID(displayReconfigurationCallback, nil)
}

/// The window server's call, once per display for each phase of a change: hands the change to the
/// main queue.
private func displayReconfigurationCallback(_ display: CGDirectDisplayID, _ uuid: CFUUID?,
                                            _ flags: CGDisplayChangeSummaryFlags, _ userInfo: UnsafeMutableRawPointer?) {
    guard display != 0 else {
        Logger().error("display reconfiguration callback without a display")
        return
    }
    let flags = flags.rawValue
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            handleDisplayReconfiguration(display: display, flags: flags)
        }
    }
}

/// The original's block (REF-OVERLAY-012): the begin flag notes the change; its first result closes
/// Launchpad; every result has the Dock bar determine its display again and, unless the flags have
/// the bit 0x2000, tells Launchpad the display changed.
@MainActor
func handleDisplayReconfiguration(display: CGDirectDisplayID, flags: UInt32) {
    if flags & CGDisplayChangeSummaryFlags.beginConfigurationFlag.rawValue != 0 {
        displayReconfigurationPending = true
        return
    }
    if displayReconfigurationPending {
        if dockStarted {
            launchpadSpringboard?.setVisible(false, reason: "display reconfig")
        }
        displayReconfigurationPending = false
    }
    guard dockStarted else { return }
    dockBar.updateDisplay(fromMainThread: true)
    if flags & 0x2000 == 0 {  // REF-OVERLAY-012
        launchpadSpringboard?.displayChanged()
    }
}

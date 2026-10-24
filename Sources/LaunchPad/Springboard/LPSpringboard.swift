import AppKit

/// Launchpad's controller as Dock creates it (REF-ARCH-005). Its override of the open and close adds
/// the window's ordering, the background check and the Dock's visibility (REF-OVERLAY-007).
@MainActor
@objc(LPSpringboard)
class LPSpringboard: Springboard {
    @objc(setVisible:slow:forGaming:reason:)
    override func setVisible(_ visible: Bool, slow: Bool, forGaming: Bool, reason: String?) {
        // REF-DEV-007: a space switch in progress refuses both directions.
        guard !spaces.anySwitchingOccurring else { return }
        guard self.visible != visible else { return }
        if !visible {
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                MainActor.assumeIsolated {
                    guard !self.visible else { return }
                    dockBar.visibilityController.removeOverrideShowType(1)  // REF-DEV-004
                    self.orderWindowOn(false)
                }
            }
            super.setVisible(false, slow: slow, forGaming: forGaming, reason: reason)
            _visibility = 0
            CATransaction.commit()
            return
        }
        // REF-DEV-007: the conditions that refuse an open, as far as they can be read.
        guard processUIModeManager.processSwitchEnabled,
              !dockGlobals.inAcceleratedTwoUp,
              !dockGlobals.reorderingTilesInFullscreen else { return }
        containerWindow().setFrame(totalScreenBounds())
        orderWindowOn(true)
        let space = spaces.currentSpace(forDisplay: display())?.uuid
        if desktopStale || desktopLastUUID == nil || desktopLastUUID != space {
            updateDesktopImages()
        }
        if showsDock() {
            dockBar.visibilityController.setOverrideShowType(1)  // REF-DEV-004
        }
        super.setVisible(true, slow: slow, forGaming: forGaming, reason: reason)
        _visibility = 1
    }

    @objc func showsDock() -> Bool {
        true
    }

    // MARK: - Launching (REF-LAUNCH-002, REF-LAUNCH-003)

    /// Zooms the icon and closes at once, then opens the app once its bookmark is resolved; does not
    /// call the superclass's (research paper §5.9). Clearing the new-app mark after the open comes
    /// with phase 6.
    override func _launchRunnable(_ runnable: LPRunnable?, withImageRect imageRect: CGRect, withEvent event: ECEvent?) {
        guard let runnable else { return }
        if let icon = runnable.icon, !dockGlobals.axReduceMotion {
            performOpenAnimation(forRunnable: runnable, withImage: icon, atFrame: imageRect,
                                 toFrame: containerWindow().convertRectFromGlobal(.zero))
        }
        setVisible(false, reason: "launch runnable in LPSpringboard subclass")  // REF-LAUNCH-003
        let item = UncheckedBox(runnable)
        runnable.resolveURLFromBookMark(true) { url in
            DispatchQueue.main.async {
                let runnable = item.value
                self._refreshItem(runnable, property: "notFound")
                guard let url, !runnable.notFound else { return }
                var toFrame = CGRect.zero
                _ = self.handleRunnableOpen(runnable, atURL: url, fromFrame: imageRect, toFrame: &toFrame)
            }
        }
    }

    /// Opens the app at `url` with LaunchServices on a global queue (REF-LAUNCH-003). The original reads
    /// the display inside the dispatched block; `DockBar` is main-actor isolated here, so it is read just
    /// before. The original's two analytics events are not copied (app-architecture).
    override func handleRunnableOpen(_ runnable: LPRunnable?, atURL url: URL?, fromFrame: CGRect,
                                     toFrame: UnsafeMutablePointer<CGRect>?) -> Bool {
        let slow = dockGlobals.slowMotionAllowed && ECModalEventController.shiftKeyDown()
        let display = dockBar.display.identifier
        if let url {
            DispatchQueue.global().async {
                openURL(url, dontSwitch: false, slow: slow, display: display)
            }
        }
        return true
    }
}

/// Dock's function that opens an item with LaunchServices, as Launchpad calls it (REF-LAUNCH-003): no
/// app to open it with, the display's identifier as the 'disp' pass-through parameter when there is
/// one, and the original's launch flags. The result is not looked at.
nonisolated func openURL(_ url: URL, dontSwitch: Bool, slow: Bool, display: UInt32) {
    let (flags, params) = launchParameters(dontSwitch: dontSwitch, slow: slow, display: display)
    let items = [url] as CFArray
    withExtendedLifetime((items, params)) {
        var spec = LSLaunchURLSpec(appURL: nil, itemURLs: Unmanaged.passUnretained(items), passThruParams: params?.aeDesc,
                                   launchFlags: LSLaunchFlags(rawValue: flags), asyncRefCon: nil)
        _ = LSOpenFromURLSpec(&spec, nil)
    }
}

/// The launch flags and the pass-through record of `openURL(_:dontSwitch:slow:display:)`
/// (REF-LAUNCH-003): kLSLaunchDefaults, 0x4 and kLSLaunchAndDisplayErrors, kLSLaunchDontSwitch when
/// asked, 0x1000000 in slow motion; a record with the display under 'disp' when it is not 0.
nonisolated func launchParameters(dontSwitch: Bool, slow: Bool, display: UInt32) -> (UInt32, NSAppleEventDescriptor?) {
    var params: NSAppleEventDescriptor?
    if display != 0 {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(int32: Int32(bitPattern: display)), forKeyword: 0x6469_7370)  // 'disp'
        params = record
    }
    var flags: UInt32 = dontSwitch ? 0x245 : 0x45
    if slow {
        flags |= 0x100_0000
    }
    return (flags, params)
}

import AppKit

/// Launchpad's controller as Dock creates it (REF-ARCH-005). Its override of the open and close adds
/// the window's ordering, the background check and the Dock's visibility (REF-OVERLAY-007).
@MainActor
@objc(LPSpringboard)
final class LPSpringboard: Springboard {
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
}

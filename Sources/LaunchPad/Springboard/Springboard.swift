import AppKit
import LaunchPadPrivate
import os

/// Launchpad's controller (REF-ARCH-005, REF-ARCH-006). This change has the window, the overlay
/// container, the background, and the open and close (REF-OVERLAY-007); the grid, events, folders
/// and the model are later sub-phases.
@MainActor
@objc(Springboard)
class Springboard: NSObject, CALayerDelegate {
    let window: WALayerKitWindow
    @objc let layer: CALayer
    let desktopContainerLayer: CALayer
    var desktopLayer: CALayer?
    let desktopFilters: [CAFilter]
    var openCount: UInt32 = 0
    var _visibility: Float = 0
    var _visible = false
    var windowIsOrderedOn = false
    var desktopStale = false
    var desktopLastUUID: String?

    override init() {
        layer = CALayer()
        desktopContainerLayer = CALayer()
        // REF-OVERLAY-005: the three background filters, created once.
        let blur = CAFilter(type: kCAFilterGaussianBlur)
        blur.setValue(kCFBooleanTrue, forKey: "inputHardEdges")
        blur.setValue(30, forKey: "inputRadius")
        let saturate = CAFilter(type: kCAFilterColorSaturate)
        saturate.setValue(1.8, forKey: "inputAmount")
        let matrix = CAFilter(type: kCAFilterColorMatrix)
        let values = CAColorMatrix(m11: 0.55, m12: 0, m13: 0, m14: 0, m15: 0.05292,
                                   m21: 0, m22: 0.55, m23: 0, m24: 0, m25: 0.05292,
                                   m31: 0, m32: 0, m33: 0.55, m34: 0, m35: 0.05292,
                                   m41: 0, m42: 0, m43: 0, m44: 1, m45: 0)
        matrix.setValue(NSValue(caColorMatrix: values), forKey: "inputColorMatrix")
        desktopFilters = [blur, saturate, matrix]
        let display = CGMainDisplayID()
        // REF-ARCH-008: tags 0x400 and level 20.
        window = WALayerKitWindow(frame: CGDisplayBounds(display), connection: dockGlobals.dockConnection,
                                  display: display, tags: 0x400, level: 20)
        super.init()
        layer.delegate = self
        layer.insertSublayer(desktopContainerLayer, at: 0)
        let wid = window.wid()
        if wid != 0 {
            CGSSetWindowProperty(Int32(bitPattern: dockGlobals.dockConnection), wid, "kCGSWindowTitle" as CFString,
                                 NSStringFromClass(type(of: self)) as CFString)
        }
    }

    /// The display Launchpad is shown on: the Dock's in the original. Only one display is handled
    /// in this sub-phase (multiple displays are 1.6).
    @objc func display() -> UInt32 {
        CGMainDisplayID()
    }

    /// The bounds of `-display` in global coordinates (REF-ARCH-008).
    @objc func totalScreenBounds() -> CGRect {
        CGDisplayBounds(display())
    }

    @objc func containerWindow() -> WALayerKitWindow {
        window
    }

    @objc var visible: Bool { _visible }

    // MARK: - Open and close (REF-OVERLAY-007)

    @objc(setVisible:reason:)
    func setVisible(_ visible: Bool, reason: String?) {
        // REF-OVERLAY-008: slow motion only when allowed and Shift is down.
        let slow = dockGlobals.slowMotionAllowed && ECModalEventController.shiftKeyDown()
        setVisible(visible, slow: slow, forGaming: false, reason: reason)
    }

    @objc(setVisible:slow:forGaming:reason:)
    func setVisible(_ visible: Bool, slow: Bool, forGaming: Bool, reason: String?) {
        Logger().info("Launchpad changing to \(visible ? "visible" : "NOT visible") for \(reason ?? "(null)")")
        guard _visible != visible else { return }
        if visible {
            // REF-DEV-007: the conditions that refuse an open, as far as they can be read.
            guard !spaces.anySwitchingOccurring, dragController.currentDragContents & 0x10 == 0 else { return }
            if wvExpose.mode != 0 {
                wvExpose.exit()
            }
        }
        _visible = visible
        _enterExitAnimation(visible, slow: slow)
    }

    @objc(_enterExitAnimation:slow:)
    func _enterExitAnimation(_ enter: Bool, slow: Bool) {
        if enter {
            prepareForEnterAnimation()
            performEnterAnimation(slow)
        } else {
            performExitAnimation(slow)
        }
    }

    @objc func prepareForEnterAnimation() {
        let connection = Int32(bitPattern: dockGlobals.dockConnection)
        if self is LPSpringboard {
            // REF-OVERLAY-006: above the menu bar. The Dock bar's window cannot be raised to 29 from
            // another process (REF-DEV-003).
            CGSSetWindowLevel(connection, containerWindow().wid(), 27)
        }
        if dockGlobals.externalMenuIsUp {
            CFNotificationCenterPostNotification(CFNotificationCenterGetDistributedCenter(),
                                                 CFNotificationName("com.apple.HIToolbox.cancelMenuTrackingNotification" as CFString),
                                                 nil, nil, true)
        }
        CPSStealKeyFocusOnConnection(connection, 0x480)
        desktopLayer?.removeFromSuperlayer()
        let desktopLayer = _newDesktopLayer()
        self.desktopLayer = desktopLayer
        let disabled = disableActions()
        _applyDesktopFilters()
        let bounds = CGDisplayBounds(display())
        containerWindow().layer.insertSublayer(layer, at: 0)
        desktopContainerLayer.insertSublayer(desktopLayer, at: 0)
        desktopContainerLayer.frame = CGRect(origin: .zero, size: bounds.size)
        layer.opacity = 0
        if disabled {
            CATransaction.setDisableActions(false)
        }
        CATransaction.flush()
    }

    @objc(performEnterAnimation:)
    func performEnterAnimation(_ slow: Bool) {
        CGSSetDisplayAcceleratorBoost(display(), 0)
        openCount += 1
        CATransaction.setAnimationDuration(Self.animationDuration(slow: slow, key: "springboard-show-duration"))
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))  // REF-OVERLAY-001
        CATransaction.begin()
        layer.opacity = 1  // REF-OVERLAY-001
        CATransaction.commit()
        WAWindow.setSafeApertureOverride(0, force: false)  // REF-DEV-011
        CoreCursorSet(Int32(bitPattern: dockGlobals.dockConnection), 0)  // REF-DEV-006
    }

    @objc(performExitAnimation:)
    func performExitAnimation(_ slow: Bool) {
        CGSSetDisplayAcceleratorBoost(display(), 0)
        CATransaction.setAnimationDuration(Self.animationDuration(slow: slow, key: "springboard-hide-duration"))
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))  // REF-OVERLAY-004
        let count = openCount
        let closingDesktopLayer = UncheckedBox(desktopLayer)
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                self._cleanupAfterExitAnimation(closingDesktopLayer.value, openCount: count)
            }
        }
        layer.opacity = 0  // REF-OVERLAY-004
        CATransaction.commit()
        WAWindow.setSafeApertureOverride(1, force: false)  // REF-DEV-011
        _cleanupBeforeExitAnimation()
        desktopLayer = nil
    }

    @objc func _cleanupBeforeExitAnimation() {
        CPSReleaseKeyFocusOnConnection(Int32(bitPattern: dockGlobals.dockConnection))
    }

    @objc(_cleanupAfterExitAnimation:openCount:)
    func _cleanupAfterExitAnimation(_ desktopLayer: CALayer?, openCount: UInt32) {
        if openCount == self.openCount, self is LPSpringboard {
            // REF-OVERLAY-006; the Dock bar's window was not raised (REF-DEV-003).
            CGSSetWindowLevel(Int32(bitPattern: dockGlobals.dockConnection), containerWindow().wid(), 20)
        }
        let disabled = disableActions()
        if !_visible {
            layer.removeFromSuperlayer()
        }
        desktopLayer?.removeFromSuperlayer()
        if disabled {
            CATransaction.setDisableActions(false)
        }
    }

    /// Orders the window on or off at once, in a window-server transaction of its own
    /// (REF-OVERLAY-007, REF-DEV-014).
    @objc(orderWindowOn:)
    func orderWindowOn(_ on: Bool) {
        windowIsOrderedOn = on
        guard let transaction = SLSTransactionCreate(Int32(bitPattern: dockGlobals.dockConnection)) else { return }
        window.orderImmediate(on ? 1 : 0, otherWindow: 0, with: OpaquePointer(Unmanaged.passUnretained(transaction).toOpaque()))
        SLSTransactionCommit(transaction, 0)
    }

    // MARK: - Background (REF-OVERLAY-003, REF-OVERLAY-005)

    /// A new background layer for the current space of the display, as large as the display.
    @objc func _newDesktopLayer() -> CALayer {
        let display = display()
        let layer = gDesktopPictureManager.layer(forSpace: spaces.currentSpace(forDisplay: display), andDisplay: display)
        layer.frame = CGRect(origin: .zero, size: CGDisplayBounds(display).size)
        return layer
    }

    @objc func _applyDesktopFilters() {
        desktopContainerLayer.shouldRasterize = true
        desktopContainerLayer.rasterizationScale = Self.scaleFactor(of: display())
        desktopContainerLayer.filters = desktopFilters
    }

    /// Replaces the background with a new capture while open (REF-OVERLAY-003). While closed there is
    /// no background layer, and when one cannot be replaced now the background is marked stale.
    @objc func updateDesktopImages() {
        guard let current = desktopLayer else { return }
        guard _visible else {
            desktopStale = true
            return
        }
        let replacement = _newDesktopLayer()
        let disabled = disableActions()
        replacement.opacity = 0
        replacement.frame = current.frame
        desktopContainerLayer.addSublayer(replacement)
        if disabled {
            CATransaction.setDisableActions(false)
        }
        CATransaction.flush()
        CATransaction.begin()
        CATransaction.setAnimationDuration(2)  // REF-OVERLAY-003
        let old = UncheckedBox(current)
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                let disabled = disableActions()
                old.value.removeFromSuperlayer()
                if disabled {
                    CATransaction.setDisableActions(false)
                }
            }
        }
        replacement.opacity = 1
        desktopLayer = replacement
        CATransaction.commit()
        desktopLastUUID = spaces.currentSpace(forDisplay: display())?.uuid
        desktopStale = false
    }

    // MARK: - Helpers

    /// The open or close duration: the slow-motion duration, else the preference, else the current
    /// transaction's (REF-OVERLAY-008). A preference that is not a number counts as unset; it is used
    /// in single precision, without clamping.
    static func animationDuration(slow: Bool, key: String) -> CFTimeInterval {
        if slow {
            return 5  // REF-OVERLAY-008
        }
        let fallback = Float(CATransaction.animationDuration())
        let value = (UserDefaults.standard.object(forKey: key) as? NSNumber)?.floatValue ?? fallback
        return CFTimeInterval(value)
    }

    /// The scale factor of a display's current mode; 1 when it cannot be read or is not positive
    /// (REF-OVERLAY-005).
    static func scaleFactor(of display: UInt32) -> CGFloat {
        guard let mode = CGDisplayCopyDisplayMode(display), mode.width > 0 else { return 1 }
        let scale = CGFloat(mode.pixelWidth) / CGFloat(mode.width)
        return scale > 0 ? scale : 1
    }
}

/// Disables implicit actions in the current transaction unless they already are; returns whether it
/// did, so the caller can enable them again.
@MainActor
func disableActions() -> Bool {
    guard !CATransaction.disableActions() else { return false }
    CATransaction.setDisableActions(true)
    return true
}

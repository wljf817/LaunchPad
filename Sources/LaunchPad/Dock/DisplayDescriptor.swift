import AppKit

/// The Dock's description of a display (REF-ARCH-010). Launchpad uses the height of its notch
/// (REF-GRID-007) and its identifier, which goes with an app it opens (REF-LAUNCH-003).
@MainActor
@objc(DisplayDescriptor)
final class DisplayDescriptor: NSObject {
    @objc let notchBounds: CGRect
    @objc let identifier: UInt32

    init(notchBounds: CGRect, identifier: UInt32 = 0) {
        self.notchBounds = notchBounds
        self.identifier = identifier
        super.init()
    }

    /// The descriptor of `display`: its identifier is the display's (REF-LAUNCH-003); its notch is the
    /// gap between the screen's two auxiliary top areas, `CGRect.null` (no height) without them
    /// (REF-DEV-020).
    static func descriptor(for display: CGDirectDisplayID) -> DisplayDescriptor {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }
        guard let left = screen?.auxiliaryTopLeftArea, let right = screen?.auxiliaryTopRightArea else {
            return DisplayDescriptor(notchBounds: .null, identifier: display)
        }
        return DisplayDescriptor(notchBounds: CGRect(x: left.maxX, y: left.minY, width: right.minX - left.maxX,
                                                     height: left.height), identifier: display)
    }
}

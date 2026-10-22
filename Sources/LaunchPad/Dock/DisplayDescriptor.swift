import AppKit

/// The Dock's description of a display (REF-ARCH-010). Launchpad uses only the height of its notch
/// (REF-GRID-007).
@MainActor
@objc(DisplayDescriptor)
final class DisplayDescriptor: NSObject {
    @objc let notchBounds: CGRect

    init(notchBounds: CGRect) {
        self.notchBounds = notchBounds
        super.init()
    }

    /// The descriptor of `display`: its notch is the gap between the screen's two auxiliary top areas,
    /// `CGRect.null` (no height) without them (REF-DEV-020).
    static func descriptor(for display: CGDirectDisplayID) -> DisplayDescriptor {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }
        guard let left = screen?.auxiliaryTopLeftArea, let right = screen?.auxiliaryTopRightArea else {
            return DisplayDescriptor(notchBounds: .null)
        }
        return DisplayDescriptor(notchBounds: CGRect(x: left.maxX, y: left.minY, width: right.minX - left.maxX,
                                                     height: left.height))
    }
}

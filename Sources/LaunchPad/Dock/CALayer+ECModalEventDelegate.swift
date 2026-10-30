import LaunchPadPrivate
import ObjectiveC
import QuartzCore

/// The key of the event delegate's associated object.
nonisolated(unsafe) private var eventDelegateKey: UInt8 = 0

/// Dock's category on `CALayer` (REF-ARCH-006): the object that handles a layer's events with the
/// `action:in:` methods. An associated object that is not retained (REF-OVERLAY-009).
extension CALayer {
    @objc var eventDelegate: AnyObject? {
        get { objc_getAssociatedObject(self, &eventDelegateKey) as AnyObject? }
        set { objc_setAssociatedObject(self, &eventDelegateKey, newValue, .OBJC_ASSOCIATION_ASSIGN) }
    }

    /// A material's look: the background color and the compositing filter that the control and the
    /// appearance give (REF-KEYBOARD-004).
    @objc(setMaterialControl:appearance:)
    func setMaterialControl(_ control: UInt, appearance: UInt) {
        let (color, filter) = materialColor(control: control, appearance: appearance)
        backgroundColor = color
        compositingFilter = filter
    }
}

/// The color and the compositing filter of a material (REF-KEYBOARD-004): appearance 1 is `plusD`
/// with one table of grays, any other appearance `plusL` with another; a control past the table is
/// gray 0. The color is an sRGB gray with alpha 1.
private func materialColor(control: UInt, appearance: UInt) -> (CGColor, String) {
    let filter: String
    let grays: [CGFloat]
    if appearance == 1 {
        filter = kCAFilterPlusD
        grays = [76, 128, 198, 232]  // REF-KEYBOARD-004
    } else {
        filter = kCAFilterPlusL
        grays = [229, 124, 65, 35]  // REF-KEYBOARD-004
    }
    let gray = control < UInt(grays.count) ? grays[Int(control)] / 255 : 0  // REF-KEYBOARD-004
    return (CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1), filter)
}

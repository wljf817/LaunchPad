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
}

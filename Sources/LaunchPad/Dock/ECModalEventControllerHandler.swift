import QuartzCore

/// A modal event handler on `ECModalEventController`'s stack, with what the dispatcher keeps for it
/// between events: the press's capture and hit layer, and whether the mouse was dragged
/// (REF-OVERLAY-009; app-architecture: kept).
@MainActor
@objc(ECModalEventControllerHandler)
final class ECModalEventControllerHandler: NSObject {
    @objc let handler: ECModalEventHandler
    @objc var mouseDownCapture: ECModalEventCapture?
    @objc var mouseDownHitLayer: CALayer?
    @objc var mouseWasDragged = false
    var usingMouseHysteresis = false

    /// The pointer position the original records for the hysteresis comes with the mouse-moved
    /// dispatch (not in this change).
    @objc(initWithHandler:usingMouseHysteresis:)
    init(handler: ECModalEventHandler, usingMouseHysteresis: Bool) {
        self.handler = handler
        self.usingMouseHysteresis = usingMouseHysteresis
        super.init()
    }
}

import QuartzCore

/// What runs once on the next release of the left button (REF-LAUNCH-004); the event is nil when the
/// handler is popped or covered instead.
typealias ECMouseUpBlock = @convention(block) (ECEvent?) -> Void

/// A modal event handler on `ECModalEventController`'s stack, with what the dispatcher keeps for it
/// between events: the press's capture and hit layer, whether the mouse was dragged, and the blocks
/// to run on the release (REF-OVERLAY-009; app-architecture: kept).
@MainActor
@objc(ECModalEventControllerHandler)
final class ECModalEventControllerHandler: NSObject {
    @objc let handler: ECModalEventHandler
    @objc var mouseDownCapture: ECModalEventCapture?
    @objc var mouseDownHitLayer: CALayer?
    var mouseUpCompletionBlocks: NSMutableArray?
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

    @objc(addCompletionBlockOnMouseUp:)
    func addCompletionBlock(onMouseUp block: @escaping ECMouseUpBlock) {
        if mouseUpCompletionBlocks == nil {
            mouseUpCompletionBlocks = NSMutableArray(capacity: 0)
        }
        mouseUpCompletionBlocks?.add(unsafeBitCast(block, to: AnyObject.self).copy())
    }

    /// Runs the registered blocks in order, each once: the list is taken off first (REF-LAUNCH-004).
    @objc(performMouseUpBlocksWithEvent:)
    func performMouseUpBlocks(with event: ECEvent?) {
        guard let blocks = mouseUpCompletionBlocks else { return }
        mouseUpCompletionBlocks = nil
        for block in blocks {
            unsafeBitCast(block as AnyObject, to: ECMouseUpBlock.self)(event)
        }
    }
}

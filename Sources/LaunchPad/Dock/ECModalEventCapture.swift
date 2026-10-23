import ObjectiveC
import QuartzCore

/// The object that handled a mouse press, with the layer it was handled for: later drags and the
/// release go to it directly (REF-OVERLAY-009). A layer, or the modal handler, captured with its
/// own `action:` (app-architecture: kept).
@MainActor
@objc(ECModalEventCapture)
class ECModalEventCapture: NSObject {
    let handler: NSObjectProtocol
    @objc var layer: CALayer?
    @objc let eventType: Int64

    @objc(modalEventCaptureWithHandler:layer:eventType:)
    class func modalEventCapture(handler: NSObjectProtocol, layer: CALayer?, eventType: Int64) -> ECModalEventCapture {
        self.init(handler: handler, layer: layer, eventType: eventType)
    }

    @objc(initWithHandler:layer:eventType:)
    required init(handler: NSObjectProtocol, layer: CALayer?, eventType: Int64) {
        self.handler = handler
        self.layer = layer
        self.eventType = eventType
        super.init()
    }

    @objc(performAction:delegateAction:withEvent:)
    func performAction(_ action: Selector, delegateAction: Selector, with event: ECEvent) -> Bool {
        guard handler.responds(to: action) else { return false }
        return sendEventAction(action, to: handler, event: event)
    }

    @objc(respondsToAction:delegateAction:)
    func responds(toAction action: Selector, delegateAction: Selector) -> Bool {
        handler.responds(to: action)
    }
}

/// A capture of a layer's event delegate: later events go to its `action:in:` with the layer
/// (REF-OVERLAY-009).
@MainActor
@objc(ECModalEventCaptureDelegate)
final class ECModalEventCaptureDelegate: ECModalEventCapture {
    @objc(performAction:delegateAction:withEvent:)
    override func performAction(_ action: Selector, delegateAction: Selector, with event: ECEvent) -> Bool {
        guard handler.responds(to: delegateAction) else { return false }
        return sendEventAction(delegateAction, to: handler, event: event, in: layer)
    }

    @objc(respondsToAction:delegateAction:)
    override func responds(toAction action: Selector, delegateAction: Selector) -> Bool {
        handler.responds(to: delegateAction)
    }
}

/// Sends an event method that returns `BOOL` (`action:`), as Dock's dispatch sends it by selector.
@MainActor
func sendEventAction(_ action: Selector, to target: NSObjectProtocol, event: ECEvent) -> Bool {
    typealias Method = @convention(c) (AnyObject, Selector, ECEvent) -> Bool
    let implementation = class_getMethodImplementation(object_getClass(target), action)
    return unsafeBitCast(implementation, to: Method.self)(target, action, event)
}

/// Sends an event delegate method that returns `BOOL` (`action:in:`).
@MainActor
func sendEventAction(_ action: Selector, to target: NSObjectProtocol, event: ECEvent, in layer: CALayer?) -> Bool {
    typealias Method = @convention(c) (AnyObject, Selector, ECEvent, CALayer?) -> Bool
    let implementation = class_getMethodImplementation(object_getClass(target), action)
    return unsafeBitCast(implementation, to: Method.self)(target, action, event, layer)
}

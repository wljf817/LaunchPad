import Foundation
import LaunchPadPrivate
import QuartzCore

/// What can be pushed on `ECModalEventController`'s handler stack (REF-OVERLAY-009).
@MainActor
@objc(ECModalEventHandler)
protocol ECModalEventHandler: NSObjectProtocol {
    @objc func handlesModalDragEvents() -> Bool

    /// The layer that gets the key events first.
    @objc func modalEventLayer() -> CALayer?

    @objc optional func modalEventProcessed()
}

/// The location of the last left button press, for the drags' distance from it.
@MainActor private var mouseDownLocation = CGPoint.zero

/// Dock's modal event controller (app-architecture: kept): a stack of modal handlers; each event goes
/// to the one on top, to the layer it hits or that layer's event delegate (REF-OVERLAY-009). Only the
/// event types this sub-phase handles are dispatched: left button press, drag and release, key down
/// and up, modifier changes and notifications.
@MainActor
@objc(ECModalEventController)
final class ECModalEventController: NSObject {
    private static let shared = ECModalEventController()

    let eventHandlers = NSMutableArray()

    @objc class func sharedController() -> ECModalEventController {
        shared
    }

    /// The live state of the Shift key, not the triggering event's flags.
    @objc class func shiftKeyDown() -> Bool {
        CGSInputModifierKeyState(0, 1)
    }

    /// Pushes `handler`. The previous top handler loses the key focus and its press. Launchpad passes
    /// `externalEventSource` YES: the events come from the process's own event source, so no
    /// connection is made here.
    @objc(addHandler:externalEventSource:usingMouseHysteresis:)
    func addHandler(_ handler: ECModalEventHandler, externalEventSource: Bool, usingMouseHysteresis: Bool) {
        let previous = eventHandlers.lastObject as? ECModalEventControllerHandler
        eventHandlers.add(ECModalEventControllerHandler(handler: handler, usingMouseHysteresis: usingMouseHysteresis))
        guard let previous else { return }
        let lostKeyFocus = #selector(ECEventHandling.lostKeyFocus(_:))
        if previous.handler.responds(to: lostKeyFocus) {
            previous.handler.perform(lostKeyFocus, with: nil)
        }
        previous.mouseDownCapture = nil
        previous.mouseDownHitLayer = nil
    }

    @objc(removeHandler:)
    func removeHandler(_ handler: ECModalEventHandler) {
        for case let (index, entry as ECModalEventControllerHandler) in eventHandlers.enumerated() where entry.handler === handler {
            eventHandlers.removeObject(at: index)
            if eventHandlers.count == index {
                entry.mouseDownCapture = nil
                entry.mouseDownHitLayer = nil
            }
            return
        }
    }

    /// Dispatches `event` to the top handler: `windows` and `topLayers` are the handler's windows and
    /// the top layer of each (REF-OVERLAY-009).
    @objc(handleEvent:windows:topLayers:windowCount:)
    func handleEvent(_ eventObject: AnyObject, windows: UnsafePointer<WALayerKitWindow>, topLayers: UnsafePointer<CALayer>,
                     windowCount: UInt64) {
        let event = eventObject as! CGEvent
        guard let entry = eventHandlers.lastObject as? ECModalEventControllerHandler else {
            CATransaction.flush()
            return
        }
        let handler = entry.handler
        var topLayer = handler.modalEventLayer()
        var ecEvent: ECEvent?
        // The hit layer, the window and the top layer it was found under.
        func hit() -> (layer: CALayer?, window: WALayerKitWindow?) {
            let result = hitTest(event.location, windows: windows, topLayers: topLayers, count: windowCount)
            if let found = result.topLayer {
                topLayer = found
            }
            return (result.layer, result.window)
        }
        switch event.type.rawValue {
        case 1:  // left button down
            if entry.mouseDownCapture == nil {
                let (layer, window) = hit()
                let ev = ECEvent(event: eventObject, hitLayer: layer, hitWindow: window, session: handler)
                entry.mouseDownHitLayer = layer
                entry.mouseDownCapture = _dispatchAction(#selector(ECEventHandling.leftMouseDown(_:)),
                                                         delegateAction: Selector(("leftMouseDown:in:")), for: ev,
                                                         withEventCapture: nil, topLayer: topLayer, hitTestLayer: layer,
                                                         handler: handler)
                mouseDownLocation = event.location
                ecEvent = ev
            }
        case 2:  // left button up
            let capture = entry.mouseDownCapture
            if capture == nil || capture?.eventType == 1 {
                let (layer, window) = hit()
                let ev = ECEvent(event: eventObject, hitLayer: layer, hitWindow: window, session: handler)
                // Moving the pointer back over the layers comes with the mouse-moved dispatch.
                entry.mouseWasDragged = false
                _ = _dispatchAction(#selector(ECEventHandling.leftMouseUp(_:)), delegateAction: Selector(("leftMouseUp:in:")),
                                    for: ev, withEventCapture: capture, topLayer: topLayer, hitTestLayer: layer,
                                    handler: handler)
                entry.mouseDownCapture = nil
                entry.mouseDownHitLayer = nil
                ecEvent = ev
            }
        case 6:  // left button dragged
            let (layer, window) = hit()
            let ev = ECEvent(event: eventObject, hitLayer: layer, hitWindow: window, session: handler)
            ev.draggedDelta = CGPoint(x: mouseDownLocation.x - event.location.x, y: mouseDownLocation.y - event.location.y)
            entry.mouseWasDragged = true
            // A system drag keeps the hit layer (phase 4).
            ev.hitLayer = entry.mouseDownHitLayer
            let action = #selector(ECEventHandling.leftMouseDragged(_:))
            let delegateAction = Selector(("leftMouseDragged:in:"))
            let capture = entry.mouseDownCapture
            let handled = capture?.responds(toAction: action, delegateAction: delegateAction) == true
                && capture?.performAction(action, delegateAction: delegateAction, with: ev) == true
            if !handled, handler.responds(to: action) {
                _ = sendEventAction(action, to: handler, event: ev)
            }
            ecEvent = ev
        case 10, 11:  // key down, key up
            let ev = ECEvent(event: eventObject, hitLayer: nil, hitWindow: nil, session: handler)
            let action = event.type.rawValue == 10 ? #selector(ECEventHandling.keyDown(_:)) : #selector(ECEventHandling.keyUp(_:))
            if let layer = topLayer, layer.responds(to: action), sendEventAction(action, to: layer, event: ev) {
                // handled by the layer
            } else if handler.responds(to: action) {
                _ = sendEventAction(action, to: handler, event: ev)
            }
            ecEvent = ev
        case 12:  // modifier keys changed
            let (layer, window) = hit()
            let ev = ECEvent(event: eventObject, hitLayer: layer, hitWindow: window, session: handler)
            _ = _dispatchAction(#selector(ECEventHandling.flagsChanged(_:)), delegateAction: Selector(("flagsChanged:in:")),
                                for: ev, withEventCapture: entry.mouseDownCapture, topLayer: topLayer, hitTestLayer: layer,
                                handler: handler)
            ecEvent = ev
        case 21:  // notification
            let code = event.getIntegerValueField(CGEventField(rawValue: 64)!)
            let lostKeyFocus = #selector(ECEventHandling.lostKeyFocus(_:))
            // REF-OVERLAY-009: the codes that reach the handler.
            if [0x1000, 0xf102, 0x4000].contains(code), handler.responds(to: lostKeyFocus) {
                let ev = ECEvent(event: eventObject, hitLayer: nil, hitWindow: nil, session: handler)
                handler.perform(lostKeyFocus, with: ev)
                ecEvent = ev
            }
        default:
            break
        }
        ecEvent?.invalidate()
        handler.modalEventProcessed?()
        CATransaction.flush()
    }

    /// Hands `event` to `capture` when there is one; otherwise to the first of the hit layer and its
    /// superlayers, up to and including `topLayer`, whose event delegate (`delegateAction`) or which
    /// itself (`action`) handles it, and last to `handler`. Returns the capture for what handled it.
    @objc(_dispatchAction:delegateAction:forEvent:withEventCapture:topLayer:hitTestLayer:handler:)
    func _dispatchAction(_ action: Selector, delegateAction: Selector, for event: ECEvent,
                         withEventCapture capture: ECModalEventCapture?, topLayer: CALayer?, hitTestLayer: CALayer?,
                         handler: ECModalEventHandler) -> ECModalEventCapture? {
        if let capture {
            return capture.performAction(action, delegateAction: delegateAction, with: event) ? capture : nil
        }
        let stop = topLayer?.superlayer
        var layer = hitTestLayer
        while let current = layer, current !== stop {
            if let delegate = current.eventDelegate as? NSObjectProtocol, delegate.responds(to: delegateAction),
               sendEventAction(delegateAction, to: delegate, event: event, in: current) {
                return ECModalEventCaptureDelegate.modalEventCapture(handler: delegate, layer: current, eventType: event.type)
            }
            if current.responds(to: action), sendEventAction(action, to: current, event: event) {
                return ECModalEventCapture.modalEventCapture(handler: current, layer: current, eventType: event.type)
            }
            layer = current.superlayer
        }
        if handler.responds(to: action), sendEventAction(action, to: handler, event: event) {
            return ECModalEventCapture.modalEventCapture(handler: handler, layer: nil, eventType: event.type)
        }
        return nil
    }
}

/// The layer under `location` (global coordinates): with one window, in that window's top layer;
/// with several, in the first window whose frame contains the location and whose top layer has a
/// layer there. Also returns the window and the top layer it was found in (REF-OVERLAY-009).
@MainActor
func hitTest(_ location: CGPoint, windows: UnsafePointer<WALayerKitWindow>, topLayers: UnsafePointer<CALayer>,
             count: UInt64) -> (layer: CALayer?, window: WALayerKitWindow?, topLayer: CALayer?) {
    func test(_ index: Int) -> CALayer? {
        let point = windows[index].convertPointFromGlobal(location)
        let topLayer = topLayers[index]
        let converted = topLayer.superlayer?.convert(point, from: nil) ?? .zero
        return topLayer.hitTest(converted)
    }
    if count == 1 {
        return (test(0), windows[0], topLayers[0])
    }
    for index in 0..<Int(count) where windows[index].frame().contains(location) {
        if let layer = test(index) {
            return (layer, windows[index], topLayers[index])
        }
    }
    return (nil, nil, nil)
}

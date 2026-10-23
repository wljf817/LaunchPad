import AppKit
import LaunchPadPrivate
import QuartzCore
import Testing
@testable import LaunchPad

// The event dispatch of REF-OVERLAY-009 with events built in the test; nothing is posted to the
// window server.

/// A layer that records the event methods it gets and returns `handles` from them.
@MainActor
final class RecordingLayer: CALayer {
    var calls: [String] = []
    var handles = true

    @objc(leftMouseDown:) func leftMouseDown(_ event: ECEvent) -> Bool { calls.append("down"); return handles }
    @objc(leftMouseUp:) func leftMouseUp(_ event: ECEvent) -> Bool { calls.append("up"); return handles }
    @objc(leftMouseDragged:) func leftMouseDragged(_ event: ECEvent) -> Bool { calls.append("dragged"); return handles }
    @objc(keyDown:) func keyDown(_ event: ECEvent) -> Bool { calls.append("keyDown"); return handles }
}

/// An event delegate that records the `action:in:` methods it gets, with the layer.
@MainActor
final class RecordingDelegate: NSObject {
    var calls: [(String, CALayer?)] = []
    var handles = true

    @objc(leftMouseDown:in:) func leftMouseDown(_ event: ECEvent, in layer: CALayer?) -> Bool { calls.append(("down", layer)); return handles }
    @objc(leftMouseUp:in:) func leftMouseUp(_ event: ECEvent, in layer: CALayer?) -> Bool { calls.append(("up", layer)); return handles }
}

/// A modal handler that records what it gets.
@MainActor
final class RecordingHandler: NSObject, ECModalEventHandler {
    let layer: CALayer?
    var calls: [String] = []
    var lostKeyFocusEvents: [ECEvent?] = []
    var processed = 0

    init(layer: CALayer?) {
        self.layer = layer
    }

    func handlesModalDragEvents() -> Bool { true }
    func modalEventLayer() -> CALayer? { layer }
    func modalEventProcessed() { processed += 1 }

    @objc(leftMouseDown:) func leftMouseDown(_ event: ECEvent) -> Bool { calls.append("down"); return true }
    @objc(keyDown:) func keyDown(_ event: ECEvent) -> Bool { calls.append("keyDown"); return true }
    @objc(lostKeyFocus:) func lostKeyFocus(_ event: ECEvent?) { lostKeyFocusEvents.append(event) }
}

func mouseEvent(_ type: CGEventType, at location: CGPoint) -> CGEvent {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .left)!
}

func keyEvent(_ keyCode: CGKeyCode, character: Int64, down: Bool = true) -> CGEvent {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)!
    event.setIntegerValueField(CGEventField(rawValue: 78)!, value: character)  // REF-OVERLAY-009
    return event
}

func notificationEvent(code: Int64) -> CGEvent {
    let event = CGEvent(source: nil)!
    event.type = CGEventType(rawValue: 21)!
    event.setIntegerValueField(CGEventField(rawValue: 64)!, value: code)  // REF-OVERLAY-009
    return event
}

@MainActor
@Suite struct ECEventTests {
    @Test("取值方法读 CGEvent 的对应字段")
    func fields() {
        let mouse = ECEvent(event: mouseEvent(.leftMouseDown, at: CGPoint(x: 12, y: 34)), hitLayer: nil, hitWindow: nil, session: nil)
        #expect(mouse.type == 1)
        #expect(mouse.location == CGPoint(x: 12, y: 34))
        let key = keyEvent(53, character: 0x1b)
        key.flags = .maskShift
        key.timestamp = 1234
        let keyECEvent = ECEvent(event: key, hitLayer: nil, hitWindow: nil, session: nil)
        #expect(keyECEvent.type == 10)
        #expect(keyECEvent.keyData == 0x1b)
        #expect(keyECEvent.flags == CGEventFlags.maskShift.rawValue)
        #expect(keyECEvent.time == 1234)
        let notification = ECEvent(event: notificationEvent(code: 0xf102), hitLayer: nil, hitWindow: nil, session: nil)
        #expect(notification.type == 21)
        #expect(notification.notifyCode == 0xf102)
    }

    @Test("invalidate 后不再持有事件和命中的对象；处理者是弱引用")
    func invalidate() {
        var handler: RecordingHandler? = RecordingHandler(layer: nil)
        let event = ECEvent(event: mouseEvent(.leftMouseDown, at: .zero), hitLayer: CALayer(), hitWindow: nil, session: handler)
        #expect(event.session === handler)
        handler = nil
        #expect(event.session == nil)
        event.invalidate()
        #expect(event.event == nil)
        #expect(event.hitLayer == nil)
        #expect(event.type == 0)
    }

    @Test("eventDelegate 不持有对象")
    func eventDelegateNotRetained() {
        let layer = CALayer()
        weak var weakDelegate: NSObject?
        autoreleasepool {
            let delegate = NSObject()
            weakDelegate = delegate
            layer.eventDelegate = delegate
            #expect(layer.eventDelegate === delegate)
        }
        #expect(weakDelegate == nil)
    }
}

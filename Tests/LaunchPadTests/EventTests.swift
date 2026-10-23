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

@MainActor
@Suite struct DispatchTests {
    let window: WALayerKitWindow
    let top = CALayer()
    let child = RecordingLayer()
    let controller = ECModalEventController()

    init() {
        let display = CGMainDisplayID()
        window = WALayerKitWindow(frame: CGDisplayBounds(display), connection: UInt32(bitPattern: CGSMainConnectionID()),
                                  display: display, tags: 0x400, level: 20)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        top.frame = window.layer.bounds
        child.frame = CGRect(x: 10, y: 10, width: 100, height: 100)
        top.addSublayer(child)
        window.layer.addSublayer(top)
        CATransaction.commit()
        CATransaction.flush()
    }

    /// The global location of `point` in the top layer's coordinates (REF-OVERLAY-009).
    func global(_ point: CGPoint) -> CGPoint {
        let frame = window.frame()
        return CGPoint(x: frame.minX + point.x, y: frame.minY + frame.height - 1 - point.y)
    }

    func send(_ event: CGEvent) {
        var windows = [window]
        var layers = [top]
        controller.handleEvent(event, windows: &windows, topLayers: &layers, windowCount: 1)
    }

    @Test("全局坐标换成窗口坐标：y 比矩形的换算少 1")
    func convertPoint() {
        let frame = window.frame()
        let point = window.convertPointFromGlobal(CGPoint(x: frame.minX + 5, y: frame.minY + 7))
        #expect(point == CGPoint(x: 5, y: frame.height - 1 - 7))
    }

    @Test("事件代理先于 layer 自己；它捕获后松开时收到带 layer 的 leftMouseUp:in:")
    func delegateFirst() {
        let handler = RecordingHandler(layer: top)
        let delegate = RecordingDelegate()
        child.eventDelegate = delegate
        controller.addHandler(handler, externalEventSource: true, usingMouseHysteresis: true)
        send(mouseEvent(.leftMouseDown, at: global(CGPoint(x: 50, y: 50))))
        send(mouseEvent(.leftMouseUp, at: global(CGPoint(x: 500, y: 500))))
        #expect(delegate.calls.map(\.0) == ["down", "up"])
        #expect(delegate.calls.allSatisfy { $0.1 === child })
        #expect(child.calls.isEmpty)
        #expect(handler.calls.isEmpty)
        child.eventDelegate = nil
    }

    @Test("layer 自己捕获后，拖动和松开都交给它，不再看位置")
    func layerCapture() {
        let handler = RecordingHandler(layer: top)
        controller.addHandler(handler, externalEventSource: true, usingMouseHysteresis: true)
        send(mouseEvent(.leftMouseDown, at: global(CGPoint(x: 50, y: 50))))
        send(mouseEvent(.leftMouseDragged, at: global(CGPoint(x: 400, y: 50))))
        send(mouseEvent(.leftMouseUp, at: global(CGPoint(x: 400, y: 50))))
        #expect(child.calls == ["down", "dragged", "up"])
        #expect(handler.calls.isEmpty)
        #expect(handler.processed == 3)
    }

    @Test("沿 layer 往上找，顶层 layer 也问；都不处理就交给处理者")
    func upToTopThenHandler() {
        let handler = RecordingHandler(layer: top)
        let delegate = RecordingDelegate()
        child.handles = false
        top.eventDelegate = delegate
        controller.addHandler(handler, externalEventSource: true, usingMouseHysteresis: true)
        send(mouseEvent(.leftMouseDown, at: global(CGPoint(x: 50, y: 50))))
        #expect(child.calls == ["down"])
        #expect(delegate.calls.map(\.0) == ["down"])
        #expect(delegate.calls.first?.1 === top)
        #expect(handler.calls.isEmpty)
        send(mouseEvent(.leftMouseUp, at: global(CGPoint(x: 50, y: 50))))

        delegate.handles = false
        send(mouseEvent(.leftMouseDown, at: global(CGPoint(x: 50, y: 50))))
        #expect(handler.calls == ["down"])
        top.eventDelegate = nil
    }

    @Test("keyDown 先给处理者的 modalEventLayer，它不处理再给处理者")
    func keyDown() {
        let keyLayer = RecordingLayer()
        let handler = RecordingHandler(layer: keyLayer)
        controller.addHandler(handler, externalEventSource: true, usingMouseHysteresis: true)
        send(keyEvent(53, character: 0x1b))
        #expect(keyLayer.calls == ["keyDown"])
        #expect(handler.calls.isEmpty)
        keyLayer.handles = false
        send(keyEvent(53, character: 0x1b))
        #expect(handler.calls == ["keyDown"])
    }

    @Test("通知码 0x1000、0xf102、0x4000 调 lostKeyFocus:，别的不调")
    func notificationCodes() {
        let handler = RecordingHandler(layer: top)
        controller.addHandler(handler, externalEventSource: true, usingMouseHysteresis: true)
        for code in [0x1000, 0xf102, 0x4000, 0x8000] as [Int64] {
            send(notificationEvent(code: code))
        }
        #expect(handler.lostKeyFocusEvents.count == 3)
        #expect(handler.lostKeyFocusEvents.allSatisfy { $0 != nil })
        #expect(handler.processed == 4)
    }

    @Test("压上新处理者时旧的收到 lostKeyFocus:nil；移走后不再分发给它")
    func handlerStack() {
        let first = RecordingHandler(layer: top)
        let second = RecordingHandler(layer: top)
        controller.addHandler(first, externalEventSource: true, usingMouseHysteresis: true)
        controller.addHandler(second, externalEventSource: true, usingMouseHysteresis: true)
        #expect(first.lostKeyFocusEvents.count == 1)
        #expect(first.lostKeyFocusEvents.first! == nil)
        child.handles = false
        send(mouseEvent(.leftMouseDown, at: global(CGPoint(x: 50, y: 50))))
        #expect(second.calls == ["down"])
        #expect(first.calls.isEmpty)
        controller.removeHandler(second)
        send(mouseEvent(.leftMouseDown, at: global(CGPoint(x: 50, y: 50))))
        #expect(second.calls == ["down"])
        #expect(first.calls == ["down"])
        controller.removeHandler(first)
        #expect(controller.eventHandlers.count == 0)
    }
}

/// A controller that records the open and close requests instead of making them.
@MainActor
final class RecordingSpringboard: Springboard {
    var reasons: [String] = []
    var handleEventResult: Bool?
    var handledEvents = 0

    override func setVisible(_ visible: Bool, reason: String?) {
        reasons.append(reason ?? "")
        _visible = visible
    }

    override func handleEvent(_ event: AnyObject) -> Bool {
        handledEvents += 1
        return handleEventResult ?? super.handleEvent(event)
    }
}

@MainActor
@Suite(.serialized) struct SpringboardEventTests {
    func makeEvent(_ cgEvent: CGEvent) -> ECEvent {
        ECEvent(event: cgEvent, hitLayer: nil, hitWindow: nil, session: nil)
    }

    @Test("Esc 关闭，Return 不关闭")
    func keys() {
        let springboard = RecordingSpringboard()
        springboard._visible = true
        #expect(springboard.keyDown(makeEvent(keyEvent(36, character: 0x0d))))
        #expect(springboard.reasons.isEmpty)
        #expect(springboard.keyDown(makeEvent(keyEvent(53, character: 0x1b))))
        #expect(springboard.reasons == ["perform cancel while visible"])
    }

    @Test("通知码 0x1000、0xf102 和 nil 关闭，0x4000 不关")
    func lostKeyFocus() {
        let springboard = RecordingSpringboard()
        for code in [0x1000, 0xf102, 0x4000] as [Int64] {
            springboard._visible = true
            springboard.lostKeyFocus(makeEvent(notificationEvent(code: code)))
        }
        springboard._visible = true
        springboard.lostKeyFocus(nil)
        #expect(springboard.reasons == ["lost key focus", "lost key focus", "lost key focus"])
    }

    @Test("不可见时 handleEvent: 返回 NO")
    func handleEventWhileHidden() {
        let springboard = Springboard()
        #expect(!springboard.handleEvent(keyEvent(53, character: 0x1b)))
    }

    @Test("Dock 栏矩形以外的左键按下关闭，矩形里的不关")
    func leftMouseDown() {
        let springboard = RecordingSpringboard()
        springboard._visible = true
        let bar = dockBar.inBarRect
        if !bar.isEmpty {
            #expect(!springboard.leftMouseDown(makeEvent(mouseEvent(.leftMouseDown, at: CGPoint(x: bar.midX, y: bar.midY)))))
            #expect(springboard.reasons.isEmpty)
        }
        let outside = CGPoint(x: bar.isEmpty ? 10 : bar.minX + 10, y: bar.isEmpty ? 10 : bar.minY - 50)
        #expect(!springboard.leftMouseDown(makeEvent(mouseEvent(.leftMouseDown, at: outside))))
        #expect(springboard.reasons == ["left mouse down outside Dock"])
    }

    @Test("取消：可见时关闭")
    func cancel() {
        let springboard = RecordingSpringboard()
        springboard.cancelAction(with: nil, sender: nil)
        #expect(springboard.reasons.isEmpty)
        springboard._visible = true
        springboard.cancelAction(with: nil, sender: nil)
        #expect(springboard.reasons == ["cancel action while visible"])
    }

    @Test("关闭动画开始时卸下处理者，不再在接收事件")
    func cleanupRemovesHandler() {
        let springboard = Springboard()
        let controller = ECModalEventController.sharedController()
        controller.addHandler(springboard, externalEventSource: true, usingMouseHysteresis: true)
        dockGlobals.springboardIsCapturingEvents = true
        eventCapturingSpringboard = springboard
        springboard._cleanupBeforeExitAnimation()
        #expect(controller.eventHandlers.count == 0)
        #expect(!dockGlobals.springboardIsCapturingEvents)
        #expect(eventCapturingSpringboard == nil)
    }


}

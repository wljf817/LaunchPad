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
    @objc(scrollWheel:) func scrollWheel(_ event: ECEvent) -> Bool { calls.append("scrollWheel"); return handles }
    @objc(gesture:) func gesture(_ event: ECEvent) -> Bool { calls.append("gesture"); return handles }
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

/// A scroll wheel event at `location` with the fixed-point deltas and the momentum phase given
/// (REF-OVERLAY-009).
func scrollEvent(dx: Double = 0, dy: Double = 0, momentum: Int64 = 0, at location: CGPoint = .zero) -> CGEvent {
    let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0)!
    event.location = location
    event.setIntegerValueField(CGEventField(rawValue: 93)!, value: Int64(dy * 65536))  // REF-OVERLAY-009
    event.setIntegerValueField(CGEventField(rawValue: 94)!, value: Int64(dx * 65536))
    event.setIntegerValueField(CGEventField(rawValue: 123)!, value: momentum)
    return event
}

/// A gesture event at `location`: gesture type, phase, and for a navigation gesture the direction
/// field and the field whose low bit flips it (REF-OVERLAY-009).
func gestureEvent(type: Int64, phase: Int64 = 0, direction: Int64 = 0, flip: Int64 = 0,
                  at location: CGPoint = .zero) -> CGEvent {
    let event = CGEvent(source: nil)!
    event.type = CGEventType(rawValue: 29)!
    event.location = location
    event.setIntegerValueField(CGEventField(rawValue: 110)!, value: type)  // REF-OVERLAY-009
    event.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
    event.setIntegerValueField(CGEventField(rawValue: 115)!, value: direction)
    event.setIntegerValueField(CGEventField(rawValue: 136)!, value: flip)
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

    @Test("滚轮的取值：定点数增量除以 65536，动量阶段不为 0 时是动量事件")
    func scrollFields() {
        let event = ECEvent(event: scrollEvent(dx: 1.5, dy: -1, momentum: 2), hitLayer: nil, hitWindow: nil, session: nil)
        #expect(event.type == 22)
        #expect(event.deltaX == 1.5)
        #expect(event.deltaY == -1)
        #expect(event.isMomentum)
        #expect(!ECEvent(event: scrollEvent(dy: 1), hitLayer: nil, hitWindow: nil, session: nil).isMomentum)
        // A wheel scrolled one line: the system's fixed-point delta is -1.
        let line = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0)!
        #expect(ECEvent(event: line, hitLayer: nil, hitWindow: nil, session: nil).deltaY == -1)
    }

    @Test("手势的类型照读；阶段只认 1、2、4、8，看最低的字节，其余为 0")
    func gestureFields() {
        func phase(_ value: Int64) -> UInt64 {
            ECEvent(event: gestureEvent(type: 6, phase: value), hitLayer: nil, hitWindow: nil, session: nil).gesturePhase
        }
        #expect(ECEvent(event: gestureEvent(type: 6), hitLayer: nil, hitWindow: nil, session: nil).gestureType == 6)
        #expect(ECEvent(event: gestureEvent(type: 6), hitLayer: nil, hitWindow: nil, session: nil).type == 29)
        #expect([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 16, 0x101, 0x104].map(phase) == [0, 1, 2, 0, 4, 0, 0, 0, 8, 0, 0, 1, 4])
    }

    @Test("导航轻扫的方向：1→1、2→0、4→2、8→3，另一字段最低位为 1 时 4、8 对调；别的手势或方向是最大整数")
    func navigationGestureType() {
        func type(_ gesture: Int64, _ direction: Int64, flip: Int64 = 0) -> Int64 {
            ECEvent(event: gestureEvent(type: gesture, direction: direction, flip: flip), hitLayer: nil, hitWindow: nil,
                    session: nil).navigationGestureType
        }
        #expect([1, 2, 4, 8].map { type(16, $0) } == [1, 0, 2, 3])
        #expect([1, 2, 4, 8].map { type(16, $0, flip: 1) } == [1, 0, 3, 2])
        #expect([4, 8].map { type(16, $0, flip: 2) } == [2, 3])
        #expect(type(16, 3) == .max)
        #expect(type(16, 0) == .max)
        #expect(type(6, 1) == .max)
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

    @Test("滚轮和手势事件按命中的 layer 往上送；按住鼠标时也不交给按下时的捕获")
    func scrollAndGesture() {
        let handler = RecordingHandler(layer: top)
        let other = RecordingLayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        other.frame = CGRect(x: 300, y: 300, width: 100, height: 100)
        top.addSublayer(other)
        CATransaction.commit()
        CATransaction.flush()
        controller.addHandler(handler, externalEventSource: true, usingMouseHysteresis: true)
        send(scrollEvent(dy: 1, at: global(CGPoint(x: 50, y: 50))))
        send(gestureEvent(type: 6, phase: 1, at: global(CGPoint(x: 50, y: 50))))
        #expect(child.calls == ["scrollWheel", "gesture"])
        send(mouseEvent(.leftMouseDown, at: global(CGPoint(x: 50, y: 50))))
        send(scrollEvent(dy: 1, at: global(CGPoint(x: 350, y: 350))))
        send(gestureEvent(type: 6, phase: 4, at: global(CGPoint(x: 350, y: 350))))
        #expect(child.calls == ["scrollWheel", "gesture", "down"])
        #expect(other.calls == ["scrollWheel", "gesture"])
        #expect(handler.calls.isEmpty)
        other.removeFromSuperlayer()
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

    @Test("松开块在交出 leftMouseUp: 之后按登记顺序各执行一次，拿到这次松开的事件")
    func mouseUpBlocks() {
        let handler = RecordingHandler(layer: top)
        controller.addHandler(handler, externalEventSource: true, usingMouseHysteresis: true)
        var log: [String] = []
        send(mouseEvent(.leftMouseDown, at: global(CGPoint(x: 50, y: 50))))
        controller.addCompletionBlock { event in log.append("first \(event?.type ?? 0) \(child.calls.last ?? "")") }
        controller.addCompletionBlock { _ in log.append("second") }
        send(mouseEvent(.leftMouseUp, at: global(CGPoint(x: 50, y: 50))))
        #expect(log == ["first 2 up", "second"])
        let entry = controller.eventHandlers.lastObject as? ECModalEventControllerHandler
        #expect(entry?.mouseUpCompletionBlocks == nil)
        send(mouseEvent(.leftMouseDown, at: global(CGPoint(x: 50, y: 50))))
        send(mouseEvent(.leftMouseUp, at: global(CGPoint(x: 50, y: 50))))
        #expect(log.count == 2)
        controller.removeHandler(handler)
    }

    @Test("按下的捕获不是左键时，松开不执行松开块")
    func mouseUpBlocksOtherCapture() {
        let handler = RecordingHandler(layer: top)
        controller.addHandler(handler, externalEventSource: true, usingMouseHysteresis: true)
        let entry = controller.eventHandlers.lastObject as! ECModalEventControllerHandler
        entry.mouseDownCapture = ECModalEventCapture.modalEventCapture(handler: child, layer: child, eventType: 3)
        var ran = false
        controller.addCompletionBlock { _ in ran = true }
        send(mouseEvent(.leftMouseUp, at: global(CGPoint(x: 50, y: 50))))
        #expect(!ran)
        entry.mouseDownCapture = nil
        controller.removeHandler(handler)
    }

    @Test("卸下栈顶处理者、压上新处理者时，原栈顶的松开块以 nil 事件执行")
    func mouseUpBlocksOnStackChanges() {
        let first = RecordingHandler(layer: top)
        let second = RecordingHandler(layer: top)
        var events: [String] = []
        controller.addHandler(first, externalEventSource: true, usingMouseHysteresis: true)
        #expect(controller.currentHandler() === first)
        controller.addCompletionBlock { event in events.append("first \(event == nil)") }
        controller.addHandler(second, externalEventSource: true, usingMouseHysteresis: true)
        #expect(controller.currentHandler() === second)
        #expect(events == ["first true"])
        controller.addCompletionBlock { event in events.append("second \(event == nil)") }
        controller.removeHandler(second)
        #expect(events == ["first true", "second true"])
        #expect(controller.currentHandler() === first)
        controller.removeHandler(first)
        #expect(controller.currentHandler() == nil)
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

    @Test("事件来源：接收事件且处理了时丢掉事件；0x400 的按键和系统定义事件不交给 handleEvent:")
    func appDelegateMonitor() throws {
        let springboard = RecordingSpringboard()
        dockGlobals.springboardIsCapturingEvents = true
        eventCapturingSpringboard = springboard
        defer {
            dockGlobals.springboardIsCapturingEvents = false
            eventCapturingSpringboard = nil
        }
        let key = try #require(NSEvent(cgEvent: keyEvent(0, character: 0x61)))
        springboard.handleEventResult = true
        #expect(LaunchPadAppDelegate.springboardEvent(key) == nil)
        springboard.handleEventResult = false
        #expect(LaunchPadAppDelegate.springboardEvent(key) === key)
        #expect(springboard.handledEvents == 2)

        let switcherKey = keyEvent(48, character: 0x09)
        switcherKey.flags = CGEventFlags(rawValue: 0x20100400)  // REF-OVERLAY-009
        let switcher = try #require(NSEvent(cgEvent: switcherKey))
        springboard.handleEventResult = true
        #expect(LaunchPadAppDelegate.springboardEvent(switcher) === switcher)
        #expect(springboard.handledEvents == 2)

        let systemDefined = try #require(NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [],
                                                            timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                                            data1: 0, data2: 0))
        #expect(systemDefined.cgEvent?.type.rawValue == 14)
        #expect(LaunchPadAppDelegate.springboardEvent(systemDefined) === systemDefined)
        #expect(springboard.handledEvents == 2)

        dockGlobals.springboardIsCapturingEvents = false
        #expect(LaunchPadAppDelegate.springboardEvent(key) === key)
        #expect(springboard.handledEvents == 2)
    }
}

@MainActor
@Suite(.serialized) struct GridClickTests {
    let springboard = RecordingSpringboard()
    let controller = ECModalEventController()

    init() {
        springboard._visible = true
        let root = springboard.containerWindow().layer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        springboard.layer.frame = root.bounds
        root.addSublayer(springboard.layer)
        springboard.springboard.layer.frame = CGRect(x: 100, y: 100, width: 600, height: 400)
        CATransaction.commit()
        controller.addHandler(springboard, externalEventSource: true, usingMouseHysteresis: true)
    }

    /// The global location of `point` in the overlay container's coordinates (REF-OVERLAY-009).
    func global(_ point: CGPoint) -> CGPoint {
        let frame = springboard.containerWindow().frame()
        return CGPoint(x: frame.minX + point.x, y: frame.minY + frame.height - 1 - point.y)
    }

    func send(_ type: CGEventType, _ point: CGPoint) {
        var windows = [springboard.containerWindow()]
        var layers = [springboard.layer]
        controller.handleEvent(mouseEvent(type, at: global(point)), windows: &windows, topLayers: &layers, windowCount: 1)
    }

    @Test("没有移动的单击走到 cancelActionWithEvent:sender: 并关闭")
    func click() {
        send(.leftMouseDown, CGPoint(x: 300, y: 300))
        #expect(springboard.reasons.isEmpty)
        send(.leftMouseUp, CGPoint(x: 300, y: 300))
        #expect(springboard.reasons == ["cancel action while visible"])
    }

    @Test("横向或纵向移动 3 点后松开不关闭，差一点时关闭")
    func dragThreshold() {
        send(.leftMouseDown, CGPoint(x: 300, y: 300))
        send(.leftMouseDragged, CGPoint(x: 303, y: 300))
        send(.leftMouseUp, CGPoint(x: 303, y: 300))
        send(.leftMouseDown, CGPoint(x: 300, y: 300))
        send(.leftMouseDragged, CGPoint(x: 300, y: 297))
        send(.leftMouseUp, CGPoint(x: 300, y: 297))
        #expect(springboard.reasons.isEmpty)
        send(.leftMouseDown, CGPoint(x: 300, y: 300))
        send(.leftMouseDragged, CGPoint(x: 302.5, y: 302.5))
        send(.leftMouseUp, CGPoint(x: 302.5, y: 302.5))
        #expect(springboard.reasons == ["cancel action while visible"])
    }

    @Test("点在 ECSBLayer 以外时由 -[Springboard leftMouseDown:] 关闭")
    func outsideGrid() {
        send(.leftMouseDown, CGPoint(x: 20, y: 700))
        #expect(springboard.reasons == ["left mouse down outside Dock"])
    }
}

@MainActor
@Suite(.serialized) struct DockSideCloseTests {
    let springboard = RecordingSpringboard()

    init() {
        launchpadSpringboard = springboard
    }

    @Test("点 Dock：只有带动作的图标算，分隔线和任何一份 LaunchPad 的都不算")
    func tileKinds() {
        #expect(DockBar.isTile(role: "AXDockItem", subrole: "AXApplicationDockItem", bundleIdentifier: "com.apple.reminders"))
        #expect(DockBar.isTile(role: "AXDockItem", subrole: "AXFolderDockItem", bundleIdentifier: nil))
        #expect(DockBar.isTile(role: "AXDockItem", subrole: "AXTrashDockItem", bundleIdentifier: nil))
        #expect(!DockBar.isTile(role: "AXDockItem", subrole: "AXSeparatorDockItem", bundleIdentifier: nil))
        #expect(!DockBar.isTile(role: "AXDockItem", subrole: "AXApplicationDockItem",
                                bundleIdentifier: "io.github.wljf817.LaunchPad.launcher"))
        #expect(!DockBar.isTile(role: "AXWindow", subrole: nil, bundleIdentifier: nil))
    }

    @Test("点 Dock：关着时什么也不做，也不记按下")
    func tileMouseWhileHidden() {
        dockBar.tileMouse(down: true, at: CGPoint(x: 10, y: 10))
        #expect(dockBar.mouseDownItem == nil)
        dockBar.tileMouse(down: false, at: CGPoint(x: 10, y: 10))
        #expect(springboard.reasons.isEmpty)
    }

    @Test("打开期间开始的菜单结束时以 menu closed 关闭，关着时开始的不关")
    func menuClosed() {
        dockGlobals.menuTrackingBegan()
        springboard._visible = true
        dockGlobals.menuTrackingEnded()
        #expect(springboard.reasons.isEmpty)
        dockGlobals.menuTrackingBegan()
        #expect(dockGlobals.externalMenuIsUp)
        dockGlobals.menuTrackingEnded()
        #expect(!dockGlobals.externalMenuIsUp)
        #expect(springboard.reasons == ["menu closed"])
    }

    @Test("调度中心换模式时以 WV change mode 关闭，关着时不动")
    func missionControl() {
        wvExpose.changedMode()
        #expect(springboard.reasons.isEmpty)
        springboard._visible = true
        wvExpose.changedMode()
        #expect(springboard.reasons == ["WV change mode"])
    }
}

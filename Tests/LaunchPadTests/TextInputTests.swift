import CoreGraphics
import CoreText
import Foundation
import LaunchPadPrivate
import QuartzCore
import Testing
@testable import LaunchPad

// The search field's side of the text input service (REF-SEARCH-011, REF-DEV-034): the connection's
// state, the hand-over of the mini view, the field's rectangle on screen and the events it forwards.
// No service runs: the connection is made to a service the test process does not have.

/// The events the field posted, with the pid they went to. LaunchPad's call of `CGEventPostToPid`
/// binds to this definition in the test bundle, so nothing reaches the window server.
nonisolated(unsafe) var postedEvents: [(pid: pid_t, event: CGEvent)] = []

@_cdecl("CGEventPostToPid")
func recordEventPostToPid(_ pid: pid_t, _ event: CGEvent?) {
    if let event {
        postedEvents.append((pid, event))
    }
}

/// The location an event has in its window.
@_silgen_name("CGEventGetWindowLocation")
func CGEventGetWindowLocation(_ event: CGEvent) -> CGPoint

/// A search field set up as the grid layer sets it up (REF-SEARCH-001), laid out at 250 × 25.
@MainActor
func makeTextInputField() -> ECTextInputLayer {
    let field = ECTextInputLayer(cgSize: CGSize(width: 250, height: 25), type: 1, scaleFactor: 1, layoutRTL: false, containerWindow: nil)
    field.font = CTFontCreateUIFontForLanguage(CTFontUIFontType(rawValue: 103)!, 16, nil)
    field.fontSize = 16
    field.foregroundColor = CGColor(gray: 1, alpha: 1)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    field.frame = CGRect(x: 0, y: 0, width: 250, height: 25)
    CATransaction.commit()
    return field
}

@MainActor
@Suite(.serialized)
struct TextInputConnectionTests {
    func uuid(_ field: ECTextInputLayer) -> [UInt8] {
        withUnsafeBytes(of: field._connection_uuid) { Array($0) }
    }

    @Test("激活后在主队列上才开始连接，并清掉「连接失效」")
    func connectsOnTheMainQueue() async {
        let field = makeTextInputField()
        field._connectionInvalid = true
        field.textFieldActive = true
        #expect(field._connection == nil)
        #expect(!field._connectionInvalid)
        await drainMainQueue()
        #expect(field._connection != nil)
        field.textFieldActive = false
    }

    @Test("断开后没连上、没焦点、没激活、事件重新排队、UUID 换了；pid、窗口号和 context id 留着")
    func closeConnection() async {
        let field = makeTextInputField()
        field.hasFocus = true
        await drainMainQueue()
        field._hasConnection = true
        field._queueEvents = false
        field._pid = 7101
        field.registerContext(0x5678, window: 0x1234)
        let before = uuid(field)
        field.textFieldActive = false
        #expect(field._connection == nil)
        #expect(!field._hasConnection)
        #expect(!field.hasFocus)
        #expect(!field.textFieldActive)
        #expect(field._queueEvents)
        #expect(uuid(field) != before)
        #expect(field._pid == 7101)
        #expect(field.windowID == 0x1234)
        #expect(field._hostLayer.contextId == 0x5678)
        field._pid = 0
    }

    @Test("服务发来的文字设成 stringValue、记下宽度，不发回服务；别处设的文字已连上时发给服务")
    func stringFromTheService() {
        final class SendRecordingField: ECTextInputLayer {
            var sent: [String?] = []

            override func _sendStringValueMessage() {
                sent.append(stringValue as String?)
            }
        }
        let field = SendRecordingField(cgSize: CGSize(width: 250, height: 25), type: 1, scaleFactor: 1, layoutRTL: false,
                                       containerWindow: nil)
        field._hasConnection = true
        field._updateStringValue("pro", width: 37, complete: false)
        #expect(field.stringValue == "pro")
        #expect(field.actualWidth == 37)
        #expect(field.sent.isEmpty)
        field.stringValue = "p"
        #expect(field.sent == ["p"])
        field._hasConnection = false
    }

    @Test("失去焦点又没有文字时，在主队列上取消激活；有文字时不取消")
    func focusLostDeactivates() async {
        let field = makeTextInputField()
        field.hasFocus = true
        await drainMainQueue()
        field.hasFocus = false
        #expect(field.textFieldActive)
        await drainMainQueue()
        #expect(!field.textFieldActive)

        field.stringValue = "pro"
        field.hasFocus = true
        await drainMainQueue()
        field.hasFocus = false
        await drainMainQueue()
        #expect(field.textFieldActive)
        field.textFieldActive = false
    }
}

@MainActor
@Suite(.serialized)
struct TextInputMiniViewTests {
    @Test("DSXSetMiniView：按 pid 找到的搜索框记下窗口号，托管 layer 显示那个 context；没有搜索框的 pid 什么也不改")
    func setMiniView() {
        let field = makeTextInputField()
        let other = makeTextInputField()
        field._pid = 7201
        other._pid = 7202
        DSXSetMiniView(window: 0x1234, contextID: 0x5678, minimizedWindow: 0, pid: 7201)
        #expect(field.windowID == 0x1234)
        #expect(field._hostLayer.contextId == 0x5678)
        DSXSetMiniView(window: 0x4321, contextID: 0x8765, minimizedWindow: 0, pid: 7203)
        #expect(field.windowID == 0x1234)
        #expect(field._hostLayer.contextId == 0x5678)
        #expect(other.windowID == 0)
        #expect(other._hostLayer.contextId == 0)
        field._pid = 0
        other._pid = 0
    }

    @Test("托管 layer 在屏幕上的矩形：先换到根 layer，再按网格窗口的位置换成全局坐标（原点在左上）")
    func hostFrame() {
        let display = CGMainDisplayID()
        let window = WALayerKitWindow(frame: CGRect(x: 100, y: 50, width: 1536, height: 960),
                                      connection: UInt32(bitPattern: CGSMainConnectionID()), display: display, tags: 0x400, level: 20)
        let grid = CALayer()
        let field = makeTextInputField()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grid.frame = CGRect(x: 0, y: 104, width: 1536, height: 856)
        field.frame = CGRect(x: 643, y: 806, width: 250, height: 25)
        grid.addSublayer(field)
        window.layer.addSublayer(grid)
        CATransaction.commit()
        field.containerWindow = window
        // The field at the reference layout: REF-SEARCH-011 has (668, 25) with the window at (0, 0).
        #expect(field._getHostFrame() == CGRect(x: 768, y: 75, width: 200, height: 25))
        grid.removeFromSuperlayer()
    }

    @Test("主网格的搜索框用控制器的窗口换算")
    func gridFieldWindow() {
        let controller = Springboard()
        #expect(controller.springboard.layer.searchTextInputLayer()?.containerWindow === controller.containerWindow())
    }
}

@MainActor
@Suite(.serialized)
struct TextInputEventTests {
    func keyEvent(_ keyCode: CGKeyCode, at location: CGPoint = .zero, timestamp: UInt64 = 0) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
        event.location = location
        event.timestamp = timestamp
        return event
    }

    func keyCodes(_ events: [CGEvent]) -> [Int64] {
        events.map { $0.getIntegerValueField(.keyboardEventKeycode) }
    }

    @Test("没连上时转发的 p、r、o 按顺序进队列，不投出去")
    func queuesUntilConnected() {
        postedEvents.removeAll()
        let field = makeTextInputField()
        for keyCode: CGKeyCode in [35, 15, 31] {
            #expect(field.handleKeyEvent(ECEvent(event: keyEvent(keyCode), hitLayer: nil, hitWindow: nil, session: nil)))
        }
        #expect(keyCodes(field._queuedEvents as! [CGEvent]) == [35, 15, 31])
        #expect(postedEvents.isEmpty)
    }

    @Test("投给服务的 pid；字段 51 是服务的窗口号，窗口内位置是事件位置减托管 layer 在屏幕上的原点；投的是副本")
    func forwardedEvent() throws {
        postedEvents.removeAll()
        let field = makeTextInputField()
        field._queueEvents = false
        field._pid = 7301
        field.registerContext(0x5678, window: 0x1234)
        field._globalHostFrame = CGRect(x: 668, y: 25, width: 200, height: 25)
        let event = keyEvent(35, at: CGPoint(x: 700, y: 40))
        field._forwardEvent(event)
        let posted = try #require(postedEvents.first)
        #expect(postedEvents.count == 1)
        #expect(posted.pid == 7301)
        #expect(posted.event !== event)
        #expect(posted.event.getIntegerValueField(CGEventField(rawValue: 51)!) == 0x1234)
        #expect(CGEventGetWindowLocation(posted.event) == CGPoint(x: 32, y: 15))
        #expect(event.getIntegerValueField(CGEventField(rawValue: 51)!) == 0)
        field._pid = 0
    }

    @Test("排着的事件按顺序投出，时间戳换成当前事件时间，队列清空")
    func pendingEvents() {
        postedEvents.removeAll()
        let field = makeTextInputField()
        for (keyCode, timestamp): (CGKeyCode, UInt64) in [(35, 1), (15, 2), (31, 3)] {
            field._forwardEvent(keyEvent(keyCode, timestamp: timestamp))
        }
        field._queueEvents = false
        let before = CGSCurrentEventTimestamp()
        field._processPendingEvents()
        let after = CGSCurrentEventTimestamp()
        #expect(keyCodes(postedEvents.map(\.event)) == [35, 15, 31])
        #expect(postedEvents.allSatisfy { $0.event.timestamp >= before && $0.event.timestamp <= after })
        #expect(field._queuedEvents == nil)
    }

    @Test("在托管 layer 上按下后，拖动、移动和抬起才转发；按在别处时不转发")
    func mouseOnTheHostLayer() {
        let field = makeTextInputField()
        func event(_ type: CGEventType, _ hitLayer: CALayer?) -> ECEvent {
            ECEvent(event: mouseEvent(type, at: .zero), hitLayer: hitLayer, hitWindow: nil, session: nil)
        }
        func count() -> Int { field._queuedEvents?.count ?? 0 }
        #expect(field.leftMouseDown(event(.leftMouseDown, field)))
        #expect(!field.leftMouseDragged(event(.leftMouseDragged, field)))
        #expect(!field.mouseMoved(event(.mouseMoved, field)))
        #expect(field.leftMouseUp(event(.leftMouseUp, field)))
        #expect(count() == 0)
        #expect(field.leftMouseDown(event(.leftMouseDown, field._hostLayer)))
        #expect(field.leftMouseDragged(event(.leftMouseDragged, field)))
        #expect(field.mouseMoved(event(.mouseMoved, field)))
        #expect(field.leftMouseUp(event(.leftMouseUp, field)))
        #expect(count() == 4)
        #expect(!field.leftMouseDragged(event(.leftMouseDragged, field._hostLayer)))
        #expect(count() == 4)
    }

    @Test("清除按钮：按下时不透明，松开后回到 0.3，文字清空")
    func cancelButton() throws {
        let display = CGMainDisplayID()
        let window = WALayerKitWindow(frame: CGRect(x: 0, y: 0, width: 1536, height: 960),
                                      connection: UInt32(bitPattern: CGSMainConnectionID()), display: display, tags: 0x400, level: 20)
        let field = makeTextInputField()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        field.frame = CGRect(x: 643, y: 910, width: 250, height: 25)
        window.layer.addSublayer(field)
        field.stringValue = "pro"
        CATransaction.commit()
        let cancel = try #require(field._cancelSearchLayer)
        let center = field.convert(CGPoint(x: cancel.frame.midX, y: cancel.frame.midY), to: window.layer)
        let location = CGPoint(x: center.x, y: 960 - 1 - center.y)
        let controller = ECModalEventController.sharedController()
        let handler = RecordingHandler(layer: field)
        controller.addHandler(handler, externalEventSource: true, usingMouseHysteresis: true)
        defer { controller.removeHandler(handler) }
        var windows = [window]
        var layers: [CALayer] = [field]
        controller.handleEvent(mouseEvent(.leftMouseDown, at: location), windows: &windows, topLayers: &layers, windowCount: 1)
        #expect(cancel.opacity == 1)
        #expect(field.stringValue == "pro")
        controller.handleEvent(mouseEvent(.leftMouseUp, at: location), windows: &windows, topLayers: &layers, windowCount: 1)
        #expect(cancel.opacity == 0.3)
        #expect(field.stringValue == "")
        #expect(cancel.isHidden)
        #expect(handler.calls.isEmpty)
        field.removeFromSuperlayer()
    }
}

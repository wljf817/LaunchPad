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

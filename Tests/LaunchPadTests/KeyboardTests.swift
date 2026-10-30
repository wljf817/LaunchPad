import CoreGraphics
import LaunchPadPrivate
import QuartzCore
import Testing
@testable import LaunchPad

// Keyboard navigation of the main grid (REF-KEYBOARD-001 to 005, research paper §9): the event's
// Command flag, the material of the selection layer, the selection layer of an item layer and the
// selected item of the pager.

@MainActor
@Suite(.serialized)
struct KeyboardTests {
    // MARK: - The Command flag (REF-KEYBOARD-001)

    @Test("commandKeyDown：flags 带 Command 位时为真，只带别的修饰键时为假")
    func commandKeyDown() {
        func event(_ flags: CGEventFlags) -> ECEvent {
            let key = keyEvent(124, character: 0xf703)
            key.flags = flags
            return ECEvent(event: key, hitLayer: nil, hitWindow: nil, session: nil)
        }
        #expect(event(.maskCommand).commandKeyDown)
        #expect(event([.maskCommand, .maskShift, .maskAlternate]).commandKeyDown)
        #expect(!event([]).commandKeyDown)
        #expect(!event([.maskShift, .maskAlternate, .maskControl, .maskSecondaryFn, .maskNumericPad]).commandKeyDown)
        #expect(!ECEvent(event: nil, hitLayer: nil, hitWindow: nil, session: nil).commandKeyDown)
    }

    // MARK: - Material (REF-KEYBOARD-004)

    func material(_ control: UInt, _ appearance: UInt) -> (components: [CGFloat], space: CFString?, filter: String?) {
        let layer = CALayer()
        layer.setMaterialControl(control, appearance: appearance)
        return (layer.backgroundColor?.components ?? [], layer.backgroundColor?.colorSpace?.name,
                layer.compositingFilter as? String)
    }

    @Test("材质：appearance 1 的四个 control 是 REF-KEYBOARD-004 的四个灰度，alpha 1、sRGB、plusD")
    func materialAppearance1() {
        for (control, gray) in [(0, 76.0), (1, 128.0), (2, 198.0), (3, 232.0)] {
            let value = material(UInt(control), 1)
            let component = CGFloat(gray / 255)
            #expect(value.components == [component, component, component, 1])
            #expect(value.space == CGColorSpace.sRGB)
            #expect(value.filter == "plusD")
        }
        #expect(kCAFilterPlusD == "plusD")
    }

    @Test("材质：其他 appearance 用另一张表和 plusL；control 大于 3 时灰度为 0")
    func materialOtherAppearances() {
        for appearance: UInt in [0, 2] {
            for (control, gray) in [(0, 229.0), (1, 124.0), (2, 65.0), (3, 35.0)] {
                let value = material(UInt(control), appearance)
                let component = CGFloat(gray / 255)
                #expect(value.components == [component, component, component, 1])
                #expect(value.space == CGColorSpace.sRGB)
                #expect(value.filter == "plusL")
            }
        }
        for (appearance, filter) in [(UInt(1), "plusD"), (0, "plusL")] {
            let value = material(4, appearance)
            #expect(value.components == [0, 0, 0, 1])
            #expect(value.filter == filter)
        }
    }
}

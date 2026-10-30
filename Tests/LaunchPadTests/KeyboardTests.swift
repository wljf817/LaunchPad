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
}

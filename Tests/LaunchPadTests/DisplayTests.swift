import AppKit
import CoreGraphics
import Testing
@testable import LaunchPad

// The multi-display handling that runs without a second display or the Dock's cooperation
// (REF-OVERLAY-011, REF-OVERLAY-012, REF-GRID-017, REF-DEV-029). The behaviour with a second
// display is checked in the comparison VM.

@MainActor
@Suite(.serialized) struct LaunchpadDisplayTests {
    @Test("Dock 窗口所在的显示器，克隆窗口不算")
    func dockWindowFrame() {
        let level = Int(CGWindowLevelForKey(.dockWindow))
        func window(_ pid: Int32, _ layer: Int, _ rect: CGRect, number: Int = 10) -> [String: Any] {
            [kCGWindowOwnerPID as String: NSNumber(value: pid), kCGWindowLayer as String: NSNumber(value: layer),
             kCGWindowBounds as String: rect.dictionaryRepresentation, kCGWindowNumber as String: NSNumber(value: number)]
        }
        let second = CGRect(x: 1536, y: 0, width: 1536, height: 960)
        let wallpaper = window(100, Int(CGWindowLevelForKey(.desktopWindow)), CGRect(x: 0, y: 0, width: 1536, height: 960))
        #expect(DockBar.dockWindowFrame(in: [wallpaper, window(100, level, second)], dockPID: 100) == second)
        #expect(DockBar.dockWindowFrame(in: [wallpaper], dockPID: 100) == nil)
        #expect(DockBar.dockWindowFrame(in: [window(200, level, second)], dockPID: 100) == nil)
        #expect(DockBar.dockWindowFrame(in: [], dockPID: 100) == nil)
        // The clone the Dock shows for a moment while it moves to another display is newer.
        let main = CGRect(x: 0, y: 0, width: 1536, height: 960)
        #expect(DockBar.dockWindowFrame(in: [window(100, level, main, number: 1122), window(100, level, second, number: 1012)],
                                        dockPID: 100) == second)
    }

    @Test("-display 是 DockBar 的显示器")
    func display() {
        let springboard = LPSpringboard()
        let saved = dockBar.display
        defer { dockBar.display = saved }
        dockBar.display = DisplayDescriptor(notchBounds: .null, identifier: 42)
        #expect(springboard.display() == 42)
        #expect(springboard.totalScreenBounds() == CGDisplayBounds(42))
    }
}

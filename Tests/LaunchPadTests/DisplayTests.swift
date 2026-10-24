import AppKit
import CoreGraphics
import Testing
@testable import LaunchPad

// The multi-display handling that runs without a second display or the Dock's cooperation
// (REF-OVERLAY-011, REF-OVERLAY-012, REF-GRID-017, REF-DEV-029). The behaviour with a second
// display is checked in the comparison VM.

/// A controller that records the closes and the display changes instead of making them.
@MainActor
final class DisplayRecordingSpringboard: LPSpringboard {
    var log: [String] = []

    override func setVisible(_ visible: Bool, reason: String?) {
        log.append("visible \(visible) \(reason ?? "")")
    }

    override func displayChanged() {
        log.append("displayChanged")
    }
}

/// A controller that records what `-displayChanged` has done when it lays out.
@MainActor
final class LayoutRecordingSpringboard: LPSpringboard {
    var layouts: [(gridVisible: Bool, pages: AnyObject?, zoomFactor: CGFloat)] = []

    override func layout() {
        layouts.append((springboard.visible, springboard.item.items as AnyObject?, springboard.zoomFactor))
        super.layout()
    }
}

@MainActor
@Suite(.serialized) struct DisplayReconfigurationTests {
    let springboard = DisplayRecordingSpringboard()
    let begin = CGDisplayChangeSummaryFlags.beginConfigurationFlag.rawValue

    /// Runs `body` with this suite's controller as Launchpad's and Dock started, and puts the globals
    /// back: other suites set `launchpadSpringboard` too, and a synchronous body cannot interleave
    /// with them.
    func withLaunchpad(_ body: () -> Void) {
        let saved = (launchpadSpringboard, displayReconfigurationPending, dockStarted)
        launchpadSpringboard = springboard
        displayReconfigurationPending = false
        dockStarted = true
        defer { (launchpadSpringboard, displayReconfigurationPending, dockStarted) = saved }
        body()
    }

    @Test("开始只记下待处理")
    func beginOnly() {
        withLaunchpad {
            handleDisplayReconfiguration(display: 1, flags: begin)
            handleDisplayReconfiguration(display: 2, flags: begin)
            #expect(displayReconfigurationPending)
            #expect(springboard.log.isEmpty)
        }
    }

    @Test("第一次结果关闭一次，每次结果都重读显示器并发 displayChanged")
    func results() {
        withLaunchpad {
            handleDisplayReconfiguration(display: 1, flags: begin)
            handleDisplayReconfiguration(display: 2, flags: begin)
            let marker = DisplayDescriptor(notchBounds: .null, identifier: 0xdead)
            dockBar.display = marker
            handleDisplayReconfiguration(display: 2, flags: 0x111a)
            #expect(dockBar.display !== marker)
            dockBar.display = marker
            handleDisplayReconfiguration(display: 1, flags: 0x1000)
            #expect(dockBar.display !== marker)
            #expect(springboard.log == ["visible false display reconfig", "displayChanged", "displayChanged"])
            #expect(!displayReconfigurationPending)
        }
    }

    @Test("带 0x2000 位的结果不发 displayChanged")
    func skippedBit() {
        withLaunchpad {
            handleDisplayReconfiguration(display: 1, flags: begin)
            handleDisplayReconfiguration(display: 1, flags: 0x2000 | 0x1000)
            #expect(springboard.log == ["visible false display reconfig"])
        }
    }

    @Test("Dock 还没启动时只清掉待处理")
    func beforeStart() {
        withLaunchpad {
            dockStarted = false
            let marker = DisplayDescriptor(notchBounds: .null, identifier: 0xdead)
            dockBar.display = marker
            handleDisplayReconfiguration(display: 1, flags: begin)
            handleDisplayReconfiguration(display: 1, flags: 0x1008)
            #expect(springboard.log.isEmpty)
            #expect(dockBar.display === marker)
            #expect(!displayReconfigurationPending)
            dockBar.updateDisplay(fromMainThread: true)
        }
    }

    @Test("Dock 改位置：方向变了才发 displayChanged")
    func dockPosition() {
        withLaunchpad {
            dockBar.observedBarOrientation = dockBar.barOrientation
            dockBar.dockRectangleChanged()
            #expect(springboard.log.isEmpty)
            let current = dockBar.barOrientation
            dockBar.observedBarOrientation = current == 0 ? 1 : 0
            dockBar.dockRectangleChanged()
            #expect(springboard.log == ["displayChanged"])
            #expect(dockBar.observedBarOrientation == current)
        }
    }
}

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

    @Test("打开时比较显示器：第一次只记下，变了才换色彩空间、重新建页")
    func checkAndUpdate() {
        let springboard = LayoutRecordingSpringboard()
        let saved = dockBar.display
        defer { dockBar.display = saved }
        let main = CGMainDisplayID()
        dockBar.display = DisplayDescriptor(notchBounds: .null, identifier: main)
        let pages = springboard.springboard.item.items as AnyObject?
        springboard.checkAndUpdateIfDisplayChanged()
        #expect(springboard.lastDisplay == main)
        #expect(springboard.springboard.item.items as AnyObject? === pages)
        springboard.checkAndUpdateIfDisplayChanged()
        #expect(springboard.springboard.item.items as AnyObject? === pages)

        springboard.lastDisplay = main &+ 1
        springboard.checkAndUpdateIfDisplayChanged()
        #expect(springboard.lastDisplay == main)
        #expect(springboard.springboard.item.items as AnyObject? !== pages)
        let expected = NSColorSpace(cgColorSpace: CGDisplayCopyColorSpace(main))
        #expect(springboard.containerWindow().mainWindow?.colorSpace == expected)
        #expect(springboard.containerWindow().stripWindow?.colorSpace == expected)
    }

    @Test("displayChanged：先藏起网格，再重新建页、取缩放系数、布局，不改 _lastDisplay")
    func displayChanged() {
        let springboard = LayoutRecordingSpringboard()
        springboard.lastDisplay = 7
        springboard.springboard.setVisible(true)
        let pages = springboard.springboard.item.items as AnyObject?
        springboard.springboard.zoomFactor = 0.5
        springboard.displayChanged()
        let layout = springboard.layouts.last
        #expect(layout?.gridVisible == false)
        #expect(layout?.pages !== pages)
        #expect(layout?.zoomFactor == springboard.getZoomFactorFromPrefs())
        #expect(springboard.lastDisplay == 7)
    }
}

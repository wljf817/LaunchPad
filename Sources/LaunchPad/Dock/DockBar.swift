import AppKit
import ApplicationServices
import LaunchPadPrivate

/// The Dock (REF-ARCH-010). Launchpad uses its visibility controller, and its tile size, distances,
/// orientation and display to leave room for it (REF-GRID-004); the Dock's own window and stacks
/// belong to the Dock process (REF-DEV-003, REF-DEV-010). It also makes the close the Dock makes on a
/// click on a tile (REF-DEV-024).
@MainActor
@objc(DockBar)
final class DockBar: NSObject {
    @objc let visibilityController: DockVisibility
    /// The display the Dock is on: Launchpad's display (REF-OVERLAY-011). In the original the Dock keeps
    /// it up to date itself; here it is read from the window server when `DockBar` is created, at every
    /// open and after a display change (REF-DEV-029).
    @objc var display: DisplayDescriptor
    /// The Dock item under the last left press while Launchpad was visible (REF-DEV-024).
    var mouseDownItem: AXUIElement?
    var mouseMonitor: Any?

    override init() {
        visibilityController = DockVisibility(spaces: spaces)
        // Without a Dock window there is no earlier value: the Dock starts on the main
        // display (REF-DEV-029).
        display = DisplayDescriptor.descriptor(for: Self.dockDisplay() ?? CGMainDisplayID())
        super.init()
        // REF-DEV-024: the clicks on the Dock go to the Dock's window; the left button is watched
        // globally instead.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            let down = event.type == .leftMouseDown
            let location = event.cgEvent?.location ?? .zero
            MainActor.assumeIsolated { dockBar.tileMouse(down: down, at: location) }
        }
    }

    // MARK: - The Dock's display and position (REF-DEV-029)

    /// Determines the Dock's display again, where the original's does after a display change
    /// (REF-OVERLAY-012); the parameter says how the original then updates the Dock's own visibility,
    /// which stays the Dock's. The display is read from the window server; while the Dock has no window
    /// (for example while it restarts) the last one is kept.
    @objc(updateDisplayFromMainThread:)
    func updateDisplay(fromMainThread: Bool) {
        guard let id = Self.dockDisplay() else { return }
        display = DisplayDescriptor.descriptor(for: id)
    }

    /// The display under the Dock's window at the Dock window level, which covers the Dock's display.
    /// The window is ordered out while the Dock hides (auto-hide, a full-screen app's space) and keeps
    /// its frame, so windows off screen count too.
    static func dockDisplay() -> CGDirectDisplayID? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
              let frame = dockWindowFrame(in: windows, dockPID: pid) else { return nil }
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(CGPoint(x: frame.midX, y: frame.midY), 1, &display, &count)
        return count == 1 ? display : nil
    }

    /// The frame (global coordinates) of the Dock process's window at the Dock window level in a
    /// window list. While the Dock moves to another display it shows a clone at the same level for a
    /// moment; the Dock's own window is the older one, with the lower window number.
    static func dockWindowFrame(in windows: [[String: Any]], dockPID: pid_t) -> CGRect? {
        let level = Int(CGWindowLevelForKey(.dockWindow))
        let dockWindows = windows.filter {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == dockPID
                && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == level
        }
        guard let window = dockWindows.min(by: {
            ($0[kCGWindowNumber as String] as? NSNumber)?.intValue ?? .max
                < ($1[kCGWindowNumber as String] as? NSNumber)?.intValue ?? .max
        }), let bounds = window[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    // MARK: - Clicks on tiles (REF-DEV-024)

    /// What the Dock does on a tile's mouse up while Launchpad is visible: a press and release on the
    /// same Dock item that is not a separator and not LaunchPad's own closes Launchpad; the item's
    /// action stays the Dock's.
    func tileMouse(down: Bool, at location: CGPoint) {
        guard let springboard = launchpadSpringboard, springboard.visible else {
            mouseDownItem = nil
            return
        }
        let item = Self.accessibilityElement(at: location)
        if down {
            mouseDownItem = item
            return
        }
        defer { mouseDownItem = nil }
        guard let pressed = mouseDownItem, let item, CFEqual(pressed, item) else { return }
        let url = Self.attribute(item, "AXURL") as? URL
        if Self.isTile(role: Self.attribute(item, kAXRoleAttribute) as? String,
                       subrole: Self.attribute(item, kAXSubroleAttribute) as? String,
                       bundleIdentifier: url.flatMap { Bundle(url: $0)?.bundleIdentifier }) {
            springboard.setVisible(false, reason: "tile mouse up not in Docklet")
        }
    }

    /// A Dock item that is a tile with an action, other than a `LaunchPad.app`'s: every copy of the
    /// launcher toggles LaunchPad itself.
    static func isTile(role: String?, subrole: String?, bundleIdentifier: String?) -> Bool {
        role == "AXDockItem" && subrole != "AXSeparatorDockItem" && bundleIdentifier != launcherBundleIdentifier
    }

    /// `LaunchPad.app`'s bundle identifier (scripts/build-app.sh).
    static let launcherBundleIdentifier = "io.github.wljf817.LaunchPad.launcher"

    static func accessibilityElement(at location: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(location.x), Float(location.y),
                                               &element) == .success else { return nil }
        return element
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    // The Dock process's state, converted from what a separate app can read of it: the Dock's
    // rectangle and position as the window server has them (REF-DEV-019). Read anew each time, as
    // Launchpad reads the Dock's current state.

    @objc var tileSize: Float {
        barGeometry().tileSize
    }

    @objc var distanceTop: Float {
        barGeometry().distanceTop
    }

    @objc var distanceBottom: Float {
        barGeometry().distanceBottom
    }

    /// 0 bottom, 1 left, 2 right (REF-GRID-004), from the window server's 2, 3, 4 (REF-DEV-019).
    @objc var barOrientation: Int {
        switch dockRect().orientation {
        case 3: return 1
        case 4: return 2
        default: return 0
        }
    }

    /// The Dock bar's rectangle in global coordinates: the window server's Dock rectangle (REF-DEV-019).
    @objc var inBarRect: CGRect {
        var rect = CGRect.zero
        var reason: Int32 = 0
        var orientation: Int32 = 0
        SLSGetDockRectWithOrientation(CGSMainConnectionID(), &rect, &reason, &orientation)
        return rect
    }

    private func barGeometry() -> (tileSize: Float, distanceTop: Float, distanceBottom: Float) {
        let dock = dockRect()
        // A Dock that would hide (auto-hide) and is shown by LaunchPad's override has no rectangle in
        // the window server; its size comes from the Dock's preference (REF-DEV-004, REF-DEV-019).
        if dock.thickness == 0, visibilityController.showOverrideFlags != 0 {
            return Self.barGeometry(preferenceSize: CoreDockGetTileSize() * 112 + 16)
        }
        return Self.barGeometry(rectThickness: Float(dock.thickness))
    }

    /// The Dock's thickness (height at the bottom, width at a side) and position, from the window
    /// server (REF-DEV-019).
    private func dockRect() -> (thickness: CGFloat, orientation: Int32) {
        var rect = CGRect.zero
        var reason: Int32 = 0
        var orientation: Int32 = 0
        SLSGetDockRectWithOrientation(CGSMainConnectionID(), &rect, &reason, &orientation)
        return (orientation == 3 || orientation == 4 ? rect.width : rect.height, orientation)
    }

    /// The original Dock's tile size and distances for a bar of the preference's size that does not
    /// shrink: the tile size is the preference's size plus twice the tile inset, and the distances
    /// follow from the tile size (REF-DEV-019).
    static func barGeometry(preferenceSize: Float) -> (tileSize: Float, distanceTop: Float, distanceBottom: Float) {
        let inset: Float = preferenceSize + 6 > 127 ? 3 : preferenceSize + 4 > 47 ? 2 : 1
        let tileSize = preferenceSize + 2 * inset
        let base: Float = tileSize > 127 ? 6 : tileSize > 47 ? 5 : tileSize > 23 ? 4 : 3
        return (tileSize, base - 2 * inset, tileSize > 47 ? 10 : 7)
    }

    /// The Dock's thickness is its rectangle's less 6, split into the tile size and the distances by the
    /// table Dock sets the distances with; all 0 while the Dock is hidden (REF-DEV-019).
    static func barGeometry(rectThickness: Float) -> (tileSize: Float, distanceTop: Float, distanceBottom: Float) {
        let thickness = rectThickness - 6
        guard thickness > 0 else { return (0, 0, 0) }
        let distances: (top: Float, bottom: Float) = thickness <= 31 ? (1, 7) : thickness <= 56 ? (2, 7)
            : thickness <= 138 ? (1, 10) : (0, 10)
        return (thickness - distances.top - distances.bottom, distances.top, distances.bottom)
    }
}

@MainActor let dockBar = DockBar()

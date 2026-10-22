import CoreGraphics
import Foundation
import QuartzCore
import LaunchPadPrivate

/// The Dock (REF-ARCH-010). Launchpad uses its visibility controller, and its tile size, distances,
/// orientation and display to leave room for it (REF-GRID-004); the Dock's own window and stacks
/// belong to the Dock process (REF-DEV-003, REF-DEV-010).
@MainActor
@objc(DockBar)
final class DockBar: NSObject {
    @objc let visibilityController: DockVisibility
    /// The display the Dock is on: Launchpad's display (REF-ARCH-008). Other displays are 1.6.
    @objc var display: DisplayDescriptor

    override init() {
        visibilityController = DockVisibility(spaces: spaces)
        display = DisplayDescriptor.descriptor(for: CGMainDisplayID())
        super.init()
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

    private func barGeometry() -> (tileSize: Float, distanceTop: Float, distanceBottom: Float) {
        var dock = dockRect()
        // An auto-hidden Dock that LaunchPad has just shown at open reaches the window server 12 to
        // 20 ms later; wait for it, at most 50 ms (REF-DEV-004, REF-DEV-019).
        if dock.thickness == 0, visibilityController.showOverrideFlags != 0 {
            let start = CACurrentMediaTime()
            while dock.thickness == 0, CACurrentMediaTime() - start < 0.05 {
                usleep(1000)
                dock = dockRect()
            }
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

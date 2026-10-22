import Foundation

/// The Dock (REF-ARCH-010). Launchpad uses its visibility controller; the Dock's own window and
/// stacks belong to the Dock process (REF-DEV-003, REF-DEV-010).
@MainActor
@objc(DockBar)
final class DockBar: NSObject {
    @objc let visibilityController: DockVisibility

    override init() {
        visibilityController = DockVisibility(spaces: spaces)
        super.init()
    }
}

@MainActor let dockBar = DockBar()

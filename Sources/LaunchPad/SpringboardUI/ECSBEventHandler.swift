import QuartzCore

/// Handles the presses, drags and releases on the items of the grid's pagers, for their pages
/// (REF-ARCH-005, REF-LAUNCH-004, research paper §5.9). `ECSBSpringboard` makes one and gives it to its
/// pager. The folder branches come with phase 5; the delete timer, and the drag once the capture takes
/// it, come with phase 4.
@MainActor
@objc(ECSBEventHandler)
final class ECSBEventHandler: NSObject {
    /// The original's ivar is `_springBoard`, its property `springboard`.
    weak var springBoard: ECSBSpringboard?
    @objc var dragCapture: ECSBDragCapture?
    var startLocation = CGPoint.zero
    var startTime: UInt64 = 0
    @objc var allowDeleting = false
    @objc var allowDragging = false
    /// Edit mode was started by this gesture, so its release does not act on the item.
    var didStartDeleting = false
    var didDrag = false

    @objc(initWithSpringboard:)
    init(springboard: ECSBSpringboard) {
        super.init()
        springBoard = springboard
        allowDeleting = true
        allowDragging = true
    }

    @objc var springboard: ECSBSpringboard? {
        springBoard
    }

    @objc var dragging: Bool {
        dragCapture?.dragging ?? false
    }

    /// A press on the item layer `layer` of `page`: on its icon the item darkens, the pager starts
    /// editing, a drag capture records the press, and the press goes on to the pager layer
    /// (REF-LAUNCH-004). Elsewhere in the item layer it returns NO, so the press goes on up the layers.
    @objc(leftMouseDown:inLayer:ofPage:)
    func leftMouseDown(_ event: ECEvent, inLayer layer: CALayer?, ofPage page: ECSBPage) -> Bool {
        didStartDeleting = false
        didDrag = false
        startLocation = event.location
        startTime = event.time
        guard let itemLayer = layer as? ECSBItemLayer else { return false }
        let pager = page.pager as? ECSBPager
        guard event.hitLayer === itemLayer.imageLayer else { return false }
        ECModalEventController.sharedController().addCompletionBlock { [self, weak itemLayer] _ in
            guard dragCapture != nil else { return }
            // Ending the magnification and the jitter comes with phase 4.
            itemLayer?.disableLayout = false
            itemLayer?.darkened = false
            dragCapture = nil
        }
        let disabled = disableActions()
        itemLayer.darkened = true
        if disabled {
            CATransaction.setDisableActions(false)
        }
        didDrag = false
        pager?.editing = true
        itemLayer.disableLayout = true
        if allowDragging {
            let capture = ECSBDragCapture(itemLayer: itemLayer, fromPage: page, usingEventHandler: self)
            dragCapture = capture
            _ = capture.leftMouseDown(event, in: layer)
        }
        return pager?.layer.leftMouseDown(event) ?? false
    }

    /// A drag from a press on `layer`: nothing while it stays within REF-LAUNCH-004's distance of the
    /// press; beyond it, the pager edits, and a drag that has left the icon undarkens the item and goes
    /// on to the pager layer.
    @objc(leftMouseDragged:inLayer:ofPage:)
    func leftMouseDragged(_ event: ECEvent, inLayer layer: CALayer?, ofPage page: ECSBPage) -> Bool {
        guard let itemLayer = layer as? ECSBItemLayer else { return false }
        let pager = page.pager as? ECSBPager
        let location = event.location
        // REF-LAUNCH-004
        if abs(startLocation.x - location.x) < 3, abs(startLocation.y - location.y) < 3 {
            return false
        }
        if pager?.editing == false {
            pager?.editing = true
            didStartDeleting = true
        }
        if event.hitLayer === itemLayer.imageLayer {
            didDrag = true
            // The drag capture takes the drag from here (phase 4).
            return false
        }
        itemLayer.darkened = false
        return pager?.layer.leftMouseDragged(event) ?? false
    }

    /// The release of a press on `layer`: off the icon without a drag it goes on to the pager layer;
    /// otherwise the item undarkens and, for an app not dragged, the pager's grid action handler acts
    /// on it (REF-LAUNCH-004).
    @objc(leftMouseUp:inLayer:ofPage:)
    func leftMouseUp(_ event: ECEvent, inLayer layer: CALayer?, ofPage page: ECSBPage) -> Bool {
        guard let itemLayer = layer as? ECSBItemLayer else { return false }
        let pager = page.pager as? ECSBPager
        if !didDrag, event.hitLayer !== itemLayer.imageLayer {
            if dragCapture?.fromInLockedRange == true {
                return false
            }
            return pager?.layer.leftMouseUp(event) ?? false
        }
        let disabled = disableActions()
        itemLayer.darkened = false
        if disabled {
            CATransaction.setDisableActions(false)
        }
        if didDrag {
            // Ending the magnification and the capture's drag come with phase 4.
            itemLayer.disableLayout = false
            return false
        }
        // A folder opens with phase 5.
        guard !itemLayer.isGroupItem else { return false }
        let index = (page.layer as? ECGridLayer)?.itemIndex(for: itemLayer) ?? UInt(NSNotFound)
        if !didStartDeleting {
            pager?.gridActionHandler?.performGridAction(at: index, with: event, sender: page)
        }
        return true
    }
}

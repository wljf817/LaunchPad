import QuartzCore

/// Follows a press on a grid item that may turn into a drag (REF-ARCH-005, REF-LAUNCH-004). The event
/// handler makes one at every press on an item's icon; the release block uses it to restore the item
/// (research paper §5.9). Only the press is handled here; the drag itself comes with phase 4.
@MainActor
@objc(ECSBDragCapture)
final class ECSBDragCapture: NSObject, ECEventHandlingDelegate {
    private weak var _eventHandler: ECSBEventHandler?
    private weak var _modalEventHandler: ECModalEventHandler?
    var item: ECSBItem?
    @objc let itemLayer: ECSBItemLayer
    @objc let pager: ECSBPager?
    var pagerHandler: ECSBDataSource?
    var pagerScrollLayer: CAScrollLayer?
    @objc let mainPager: ECSBPager?
    var mainPagerHandler: ECSBDataSource?
    var mainPagerScrollLayer: CAScrollLayer?
    var rootLayer: CALayer?
    var lastLocation = CGPoint.zero
    var lastTime: UInt64 = 0
    var stateStack: NSMutableArray?
    var beginningState: ECSBBeginningDragState?
    @objc var newGroupIndex: UInt = 0
    @objc var lastGroupIndex: UInt = 0
    var imageFrame = CGRect.zero
    private var _dragging = false
    var dragStarted = false
    private var _dragCanceled = false
    private var _fromInLockedRange = false
    var removingFilter = false
    var didDragIntoGroup = false
    var canStartGroup = false
    @objc var madeNewGroup = false
    @objc var shouldCallDragComplete = false
    var dragCanceledWhileFiltering = false

    /// Records the item, its page's pager and the main pager with their handlers and scroll layers,
    /// and starts the state stack with a beginning state (research paper §5.9).
    @objc(initWithItemLayer:fromPage:usingEventHandler:)
    init(itemLayer: ECSBItemLayer, fromPage page: ECSBPage, usingEventHandler eventHandler: ECSBEventHandler) {
        self.itemLayer = itemLayer
        pager = page.pager as? ECSBPager
        mainPager = eventHandler.springboard?.pager
        super.init()
        _eventHandler = eventHandler
        _modalEventHandler = ECModalEventController.sharedController().currentHandler()
        item = itemLayer.item
        pagerScrollLayer = pager?.layer.scrollLayer
        pagerHandler = pager?.handler
        mainPagerScrollLayer = mainPager?.layer.scrollLayer
        mainPagerHandler = mainPager?.handler
        rootLayer = mainPager?.layer
        // The main pager's shown folder comes with phase 5; without one it is nil.
        let state = ECSBBeginningDragState(dragCapture: self, pager: pager, page: page, group: nil, item: item,
                                           rootLayer: rootLayer)
        beginningState = state
        state.groupPage = mainPager?.currentPage
        stateStack = NSMutableArray(object: state)
        imageFrame = itemLayer.imageLayer.frame
    }

    @objc var eventHandler: ECSBEventHandler? {
        _eventHandler
    }

    @objc var modalEventHandler: ECModalEventHandler? {
        _modalEventHandler
    }

    @objc var dragging: Bool {
        _dragging
    }

    @objc var dragCanceled: Bool {
        _dragCanceled
    }

    @objc var fromInLockedRange: Bool {
        _fromInLockedRange
    }

    /// The press: the beginning state records the item's index and the pressed point and the item
    /// layer's frame in the scroll layer (research paper §5.9).
    @objc(leftMouseDown:in:)
    func leftMouseDown(_ event: ECEvent, in layer: CALayer?) -> Bool {
        dragStarted = false
        beginningState?.pager?.selectedItem = nil
        let gridLayer = beginningState?.page?.layer as? ECGridLayer
        beginningState?.itemIndex = gridLayer?.itemIndex(for: itemLayer) ?? UInt(NSNotFound)
        let point = event.hitWindow?.convertPointFromGlobal(event.location) ?? event.location
        beginningState?.location = pagerScrollLayer?.convert(point, from: nil) ?? point
        // As the original: the item layer's frame is converted from the page's grid layer.
        beginningState?.frame = gridLayer?.convert(itemLayer.frame, to: pagerScrollLayer) ?? itemLayer.frame
        lastLocation = beginningState?.location ?? .zero
        lastTime = event.time
        lastGroupIndex = UInt(NSNotFound)
        newGroupIndex = UInt(NSNotFound)
        removingFilter = false
        didDragIntoGroup = false
        canStartGroup = true
        madeNewGroup = false
        shouldCallDragComplete = true
        dragCanceledWhileFiltering = false
        return true
    }
}

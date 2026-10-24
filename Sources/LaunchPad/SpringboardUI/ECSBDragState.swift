import QuartzCore

/// A state of a drag of a grid item: the drag capture keeps a stack of them (REF-ARCH-005, research
/// paper §10). Only the record made by a press is built here (research paper §5.9); the states'
/// transitions come with phase 4.
@MainActor
@objc(ECSBDragState)
class ECSBDragState: NSObject {
    @objc weak var pager: ECSBPager?
    @objc weak var page: ECSBPage?
    @objc weak var groupPage: ECSBPage?
    @objc weak var group: ECSBGroup?
    @objc weak var item: ECSBItem?
    @objc weak var rootLayer: CALayer?
    @objc weak var dragCapture: ECSBDragCapture?
    @objc var itemIndex = UInt(NSNotFound)
    @objc var hasTransitioned = false
    @objc var transitioning = false

    @objc(initWithDragCapture:pager:page:group:item:rootLayer:)
    init(dragCapture: ECSBDragCapture?, pager: ECSBPager?, page: ECSBPage?, group: ECSBGroup?, item: ECSBItem?,
         rootLayer: CALayer?) {
        super.init()
        self.dragCapture = dragCapture
        self.pager = pager
        self.page = page
        self.group = group
        self.item = item
        self.rootLayer = rootLayer
    }
}

/// The state a drag starts in: where the item was pressed, in the pager's scroll layer
/// (research paper §5.9).
@MainActor
@objc(ECSBBeginningDragState)
final class ECSBBeginningDragState: ECSBDragState {
    @objc var location = CGPoint.zero
    @objc var frame = CGRect.zero

    @objc(initWithDragCapture:pager:page:group:item:rootLayer:)
    override init(dragCapture: ECSBDragCapture?, pager: ECSBPager?, page: ECSBPage?, group: ECSBGroup?, item: ECSBItem?,
                  rootLayer: CALayer?) {
        super.init(dragCapture: dragCapture, pager: pager, page: page, group: group, item: item, rootLayer: rootLayer)
        hasTransitioned = true
    }
}

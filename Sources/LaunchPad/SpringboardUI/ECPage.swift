import QuartzCore

/// One page of a pager; its layer is the page's grid layer (REF-ARCH-005, research paper §6.2).
@MainActor
@objc(ECPage)
class ECPage: NSObject {
    weak var pager: ECPager?
    @objc var layer: CALayer?
    @objc var index: UInt
    var items: NSMutableArray?

    @objc(initWithPager:andLayer:forIndex:withItems:)
    init(pager: ECPager?, layer: CALayer?, index: UInt, items: NSMutableArray?) {
        self.index = index
        self.items = items
        super.init()
        self.pager = pager
        self.layer = layer
    }

    /// A page that goes away takes its grid layer out of the tree.
    isolated deinit {
        let disabled = disableActions()
        layer?.removeFromSuperlayer()
        if disabled {
            CATransaction.setDisableActions(false)
        }
    }
}

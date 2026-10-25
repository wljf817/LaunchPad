import QuartzCore

/// Pages side by side in a horizontally scrolling layer, the base of the grid's pager
/// (REF-ARCH-005, research paper §6.2). The pager source makes the pages; the pager layer lays them
/// out.
@MainActor
@objc(ECPager)
class ECPager: NSObject {
    var _layer: ECPagerLayer!
    @objc weak var pagerSource: ECPagerSource?
    var _pages = NSMutableArray(capacity: 0)
    var layoutRTL = false

    @objc(initWithPagerSource:layoutRTL:)
    init(pagerSource: ECPagerSource?, layoutRTL: Bool) {
        super.init()
        self.pagerSource = pagerSource
        self.layoutRTL = layoutRTL
        _layer = pagerLayerClass().init(pager: self, layoutRTL: layoutRTL)
    }

    @objc var layer: ECPagerLayer {
        _layer
    }

    @objc var pages: NSMutableArray {
        _pages
    }

    @objc var currentPageIndex: UInt {
        _layer.currentPageIndex
    }

    /// The pager layer's (REF-PAGING-003).
    @objc var pagerControlVisibility: Int {
        get { _layer.pagerControlVisibility }
        set { _layer.pagerControlVisibility = newValue }
    }

    @objc func pagerLayerClass() -> ECPagerLayer.Type {
        ECPagerLayer.self
    }

    /// Drops every page and its grid layer; the pager layer then makes the pages again.
    @objc func invalidate() {
        let disabled = disableActions()
        for case let page as ECPage in pages {
            page.layer?.removeFromSuperlayer()
            page.layer = nil
        }
        if disabled {
            CATransaction.setDisableActions(false)
        }
        _pages.removeAllObjects()
        _layer.invalidate()
    }
}

import QuartzCore

/// Pages side by side in a horizontally scrolling layer, the base of the grid's pager
/// (REF-ARCH-005, research paper §6.2). The pager source makes the pages; the pager layer lays them
/// out.
@MainActor
@objc(ECPager)
class ECPager: NSObject, ECEventHandling, ECEventHandlingDelegate, ECKeyboardNavigating {
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

    /// The pager layer's (REF-PAGING-001).
    @objc var currentPageIndex: UInt {
        get { _layer.currentPageIndex }
        set { _layer.setCurrentPageIndex(newValue) }
    }

    /// Stops the current page and the scroll value from changing. Nothing sets it in the original, so
    /// it stays NO (REF-PAGING-001).
    @objc var disableScrolling = false

    /// Sent by the pager layer before and after the current page changes; empty here (REF-PAGING-001).
    @objc(willChangeToPageIndex:)
    func willChangeToPageIndex(_ index: UInt) {}

    @objc(didChangeToPageIndex:)
    func didChangeToPageIndex(_ index: UInt) {}

    /// The pager layer's (REF-PAGING-003).
    @objc var pagerControlVisibility: Int {
        get { _layer.pagerControlVisibility }
        set { _layer.pagerControlVisibility = newValue }
    }

    /// Right goes to the next page and Left to the previous one, without a selection; any other type
    /// does nothing (REF-KEYBOARD-002). `ECSBPager` overrides it without calling it.
    @objc(navigate:withEvent:)
    func navigate(_ type: Int64, with event: ECEvent?) -> Bool {
        let count = pagerSource?.numberOfPages(for: self) ?? 0
        let current = currentPageIndex
        let step: Int
        if type == 3 {
            guard count != 0, current < count - 1 else { return false }
            step = 1
        } else {
            guard type == 2, current != 0 else { return false }
            step = -1
        }
        currentPageIndex = UInt(Int(currentPageIndex) + step)
        return true
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

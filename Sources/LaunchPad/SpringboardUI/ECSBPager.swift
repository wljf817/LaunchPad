import QuartzCore

/// The main grid's pager (REF-ARCH-005). Its layer is an `ECSBLayer`.
@MainActor
@objc(ECSBPager)
class ECSBPager: ECPager {
    /// The controller (research paper §6.1); a folder asks it for its mini icons (REF-GRID-013).
    @objc weak var handler: ECSBDataSource?
    var scaleFactor: Float = 0

    @objc(initWithPagerSource:scaleFactor:layoutRTL:)
    init(pagerSource: ECPagerSource?, scaleFactor: Float, layoutRTL: Bool) {
        super.init(pagerSource: pagerSource, layoutRTL: layoutRTL)
        self.scaleFactor = scaleFactor
        // As the original: ECPager's initializer has already made an ECSBLayer; it is replaced by
        // one made with the scale factor, and the page list by a new one (research paper §6.2).
        _layer = (pagerLayerClass() as! ECSBLayer.Type).init(pager: self, scaleFactor: scaleFactor, layoutRTL: layoutRTL)
        _pages = NSMutableArray(capacity: 0)
    }

    @objc override func pagerLayerClass() -> ECPagerLayer.Type {
        ECSBLayer.self
    }

    /// Reloads the item contents of every page, or of every page but the current one
    /// (REF-GRID-014). An open folder's pages are not among them.
    @objc(reloadItemContents:)
    func reloadItemContents(_ exceptCurrentPage: Bool) {
        let current = currentPageIndex < UInt(_pages.count) ? _pages[Int(currentPageIndex)] as AnyObject : nil
        for case let page as ECSBPage in _pages {
            if !(exceptCurrentPage && page === current) {
                page.reloadItemContents()
            }
        }
    }
}

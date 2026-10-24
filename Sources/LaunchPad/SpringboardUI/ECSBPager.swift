import QuartzCore

/// The main grid's pager (REF-ARCH-005). Its layer is an `ECSBLayer`.
@MainActor
@objc(ECSBPager)
class ECSBPager: ECPager {
    /// The controller (research paper §6.1); a folder asks it for its mini icons (REF-GRID-013).
    @objc weak var handler: ECSBDataSource?
    /// Handles the actions on the grid: `ECSBSpringboard` (REF-OVERLAY-010).
    @objc weak var gridActionHandler: ECSBGridActionHandling?
    var _selectedItem: ECSBItem?
    var scaleFactor: Float = 0
    var _editing = false
    var _visible = false

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

    /// Drops the icon contents of every page, or of every page but the current one (REF-GRID-015).
    @objc(purgeItemContents:)
    func purgeItemContents(_ exceptCurrentPage: Bool) {
        let current = currentPageIndex < UInt(_pages.count) ? _pages[Int(currentPageIndex)] as AnyObject : nil
        for case let page as ECSBPage in _pages {
            if !(exceptCurrentPage && page === current) {
                page.purgeItemContents()
            }
        }
    }

    /// Sets the editing flag of the pager and of its pages, then tells the handler, whether or not the
    /// flag changed (research paper §5.9). The open folder's branch comes with phase 5; removing the
    /// empty pages when editing ends without a drag comes with phase 4.
    @objc var editing: Bool {
        get { _editing }
        set {
            if _editing != newValue {
                _editing = newValue
                for case let page as ECSBPage in _pages {
                    page.editing = newValue
                }
            }
            let delegate = handler as? ECSBDelegate
            if newValue {
                delegate?.didBeginEditing?()
            } else {
                delegate?.didEndEditing?()
            }
        }
    }

    /// The page at the current page index, nil past the end (research paper §5.9).
    @objc var currentPage: ECSBPage? {
        let index = currentPageIndex
        return index < UInt(_pages.count) ? _pages[Int(index)] as? ECSBPage : nil
    }

    /// The selected item. Setting the same item does nothing; changing the selection (the handler's
    /// selection callbacks and the item layers' selected look) comes with phase 2 (research paper §5.9).
    @objc var selectedItem: ECSBItem? {
        get { _selectedItem }
        set {
            guard newValue !== _selectedItem else { return }
            _selectedItem = newValue
        }
    }

    @objc var visible: Bool { _visible }

    /// Passes the visibility to the item layers of every page, and of a folder's items when they have
    /// layers (REF-GRID-015). Marking the current page as recently viewed comes with the phase that
    /// reads it.
    @objc(setVisible:)
    func setVisible(_ visible: Bool) {
        guard _visible != visible else { return }
        _visible = visible
        for case let page as ECSBPage in _pages {
            for case let item as ECSBItem in page.item.items ?? [] {
                item.itemLayer?.setVisible(_visible)
                if let groupItem = item as? ECSBGroupItem {
                    for case let groupChild as ECSBItem in groupItem.items ?? [] {
                        groupChild.itemLayer?.setVisible(_visible)
                    }
                }
            }
        }
    }
}

import QuartzCore

/// The main grid's pager (REF-ARCH-005). Its layer is an `ECSBLayer`.
@MainActor
@objc(ECSBPager)
class ECSBPager: ECPager {
    /// The controller (research paper §6.1); a folder asks it for its mini icons (REF-GRID-013).
    @objc weak var handler: ECSBDataSource?
    /// Handles the actions on the grid: `ECSBSpringboard` (REF-OVERLAY-010).
    @objc weak var gridActionHandler: ECSBGridActionHandling?
    /// `ECSBSpringboard`'s, which holds it (research paper §5.9).
    @objc weak var eventHandler: ECSBEventHandler?
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

    /// Whether the scroll wheel and gestures may scroll the pages: not while an item is dragged
    /// (REF-PAGING-006). The folder conditions are phase 5.
    @objc func canScroll() -> Bool {
        eventHandler?.dragCapture == nil
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

    /// The selected item (REF-KEYBOARD-003). Setting the same item does nothing. Otherwise the handler
    /// is told before and after, with the two model items, when it responds; in between the old
    /// item's layer is deselected, the new item stored and its layer selected.
    @objc var selectedItem: ECSBItem? {
        get { _selectedItem }
        set {
            let oldItem = _selectedItem
            guard newValue !== oldItem else { return }
            if let handler = handler as? ECSBDelegate,
               handler.responds(to: #selector(ECSBDelegate.selectionWillChange(fromItem:toItem:inPager:))) {
                handler.selectionWillChange?(fromItem: oldItem?.clientItem, toItem: newValue?.clientItem, inPager: self)
            }
            oldItem?.itemLayer?.selected = false
            _selectedItem = newValue
            newValue?.itemLayer?.selected = true
            if let handler = handler as? ECSBDelegate,
               handler.responds(to: #selector(ECSBDelegate.selectionDidChange(fromItem:toItem:inPager:))) {
                handler.selectionDidChange?(fromItem: oldItem?.clientItem, toItem: _selectedItem?.clientItem, inPager: self)
            }
        }
    }

    @objc var visible: Bool { _visible }

    /// Passes the visibility to the item layers of every page, and of a folder's items when they have
    /// layers (REF-GRID-015); only the current page stays recently viewed (REF-PAGING-001).
    @objc(setVisible:)
    func setVisible(_ visible: Bool) {
        guard _visible != visible else { return }
        _visible = visible
        let current = currentPageIndex
        for case let (index, page as ECSBPage) in _pages.enumerated() {
            for case let item as ECSBItem in page.item.items ?? [] {
                item.itemLayer?.setVisible(_visible)
                if let groupItem = item as? ECSBGroupItem {
                    for case let groupChild as ECSBItem in groupItem.items ?? [] {
                        groupChild.itemLayer?.setVisible(_visible)
                    }
                }
            }
            page.recentlyViewed = UInt(index) == current
        }
    }

    // MARK: - Page changes (REF-PAGING-001)

    /// Clears the selection, then tells the pager source and the handler, when they respond; the
    /// handler gets the page's model page.
    @objc(willChangeToPageIndex:)
    override func willChangeToPageIndex(_ index: UInt) {
        selectedItem = nil
        if let pagerSource, pagerSource.responds(to: #selector(ECPagerSource.willChangeToPageIndex(_:))) {
            pagerSource.willChangeToPageIndex?(index)
        }
        let page = _pages[Int(index)] as? ECSBPage
        if let handler = handler as? ECSBDelegate, handler.responds(to: #selector(ECSBDelegate.willChangeToPage(_:))) {
            handler.willChangeToPage?(page?.item.clientItem)
        }
    }

    @objc(didChangeToPageIndex:)
    override func didChangeToPageIndex(_ index: UInt) {
        if let pagerSource, pagerSource.responds(to: #selector(ECPagerSource.didChangeToPageIndex(_:))) {
            pagerSource.didChangeToPageIndex?(index)
        }
        let page = _pages[Int(index)] as? ECSBPage
        if let handler = handler as? ECSBDelegate, handler.responds(to: #selector(ECSBDelegate.didChangeToPage(_:))) {
            handler.didChangeToPage?(page?.item.clientItem)
        }
    }
}

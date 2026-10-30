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

    // MARK: - Keys (REF-KEYBOARD-005)

    /// Return and Enter perform the selected item; any other key returns NO. An alert panel gets the
    /// key first (phase 4).
    @objc(keyDown:)
    func keyDown(_ event: ECEvent) -> Bool {
        let key = event.keyData
        guard key == 0x0D || key == 0x03 else { return false }  // Return, Enter (REF-KEYBOARD-005)
        return performAction(event)
    }

    @objc(keyUp:)
    func keyUp(_ event: ECEvent) -> Bool {
        false
    }

    /// An app goes to the handler with this pager as the sender, as a click does (REF-LAUNCH-002), and
    /// the result is NO. Without a selected item, NO; with a folder shown its group pager gets the key
    /// (phase 5). A folder opens with its first item selected and the result is YES (phase 5).
    @objc(performAction:)
    func performAction(_ event: ECEvent?) -> Bool {
        guard let selected = _selectedItem else { return false }
        if selected is ECSBGroupItem {
            // Opening the folder with its first item selected comes with phase 5.
            return true
        }
        (handler as? ECSBActionHandling)?.performAction(forItem: selected.clientItem, with: event, sender: self)
        // The Dock's flag that makes the Dock bar drop the next key up is not set (REF-DEV-012).
        return false
    }

    // MARK: - Navigation (REF-KEYBOARD-002)

    /// Nothing while an item is dragged. With Command, Left and Right change the page (swapped right
    /// to left); types 4 and 5 change it without Command. When that does not return YES, the page of
    /// the selected item moves the selection, or, without one, the page that was current at the start.
    /// So with no item selected, Command-Right scrolls to the next page and then selects the first
    /// item of the page it left; on the first or the last page, or while the pages cannot scroll,
    /// Command-Left and Command-Right move the selection as Left and Right do.
    @objc(navigate:withEvent:)
    func navigate(_ type: Int64, with event: ECEvent?) -> Bool {
        guard eventHandler?.dragging != true else { return false }
        let layoutRTL = layoutRTL
        let count = pagerSource?.numberOfPages(for: self) ?? 0
        let index = currentPageIndex
        let page = index < UInt(_pages.count) ? _pages[Int(index)] as? ECSBPage : nil
        // Both select the first item of the new page when an item was selected before.
        let previousPage = { () -> Bool in
            guard self.canScroll(), index != 0 else { return false }
            let selected = self._selectedItem
            self.currentPageIndex = self.currentPageIndex - 1
            if selected != nil, let first = self.currentPage?.item.items?.firstObject as? ECSBItem {
                self.selectedItem = first
            }
            return true
        }
        // YES only when an item was selected before, although the page changes either way.
        let nextPage = { () -> Bool in
            guard self.canScroll(), count != 0, index < count - 1 else { return false }
            let selected = self._selectedItem
            self.currentPageIndex = self.currentPageIndex + 1
            guard selected != nil else { return false }
            if let first = self.currentPage?.item.items?.firstObject as? ECSBItem {
                self.selectedItem = first
            }
            return true
        }
        let commandPreviousPage = { () -> Bool in
            event?.commandKeyDown == true ? previousPage() : false
        }
        let commandNextPage = { () -> Bool in
            event?.commandKeyDown == true ? nextPage() : false
        }
        let pageChange: (() -> Bool)?
        switch type {
        case 1:  // Down
            if _selectedItem != nil, event?.commandKeyDown == true, _selectedItem is ECSBGroupItem {
                // Opening the folder with its first item selected comes with phase 5.
                return true
            }
            pageChange = nil
        case 2:  // Left
            pageChange = layoutRTL ? commandNextPage : commandPreviousPage
        case 3:  // Right
            pageChange = layoutRTL ? commandPreviousPage : commandNextPage
        case 4:  // next page
            pageChange = layoutRTL ? previousPage : nextPage
        case 5:  // previous page
            pageChange = layoutRTL ? nextPage : previousPage
        default:
            pageChange = nil
        }
        if let pageChange, pageChange() {
            return true
        }
        if let selected = _selectedItem {
            if let pageItem = selected.parent as? ECSBPageItem {
                return pageItem.page?.navigate(type, with: event) ?? false
            }
            // An item whose parent's parent is a folder goes to the folder's group (phase 5).
            return false
        }
        // The shown folder comes before the page (phase 5).
        return page?.navigate(type, with: event) ?? false
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

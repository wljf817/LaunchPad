import QuartzCore

/// A page of the main grid (REF-ARCH-005). It is its grid layer's layer source: the items of its page
/// item give the grid layer's item count and item layers (research paper §6.2).
@MainActor
@objc(ECSBPage)
class ECSBPage: ECPage, ECLayerSource, ECEventHandlingDelegate, ECKeyboardNavigating, ECSBGridDataSource {
    @objc var handler: ECSBDataSource?
    @objc var item: ECSBPageItem
    var scaleFactor: Float
    var layoutRTL: Bool
    @objc var editing = false
    /// Set on the current page when the page changes and when the overlay is shown or hidden; read
    /// nowhere (REF-PAGING-001).
    @objc var recentlyViewed = false

    @objc(initWithPager:andLayer:forIndex:withItem:scaleFactor:layoutRTL:)
    init(pager: ECPager?, layer: CALayer?, index: UInt, item: ECSBPageItem, scaleFactor: Float, layoutRTL: Bool) {
        self.item = item
        self.scaleFactor = scaleFactor
        self.layoutRTL = layoutRTL
        super.init(pager: pager, layer: layer, index: index, items: nil)
    }

    // MARK: - ECLayerSource

    func numberOfItems(for layer: CALayer) -> UInt {
        UInt(item.items?.count ?? 0)
    }

    /// A folder gets an `ECSBGroupItemLayer` and its `ECSBGroup`, anything else an `ECSBItemLayer`;
    /// the item and its layer point to each other, and the page handles the layer's events (research
    /// paper §6.2, §11).
    func makeLayer(for layer: CALayer, at index: UInt) -> CALayer? {
        var gridItem: ECSBItem?
        if let items = item.items, index < items.count {
            gridItem = items[Int(index)] as? ECSBItem
            let kind = handler?.value(forKey: "kind", ofItem: gridItem?.clientItem, withInfo: nil) as? String
            if kind == "group", let groupItem = gridItem as? ECSBGroupItem {
                let itemLayer = ECSBGroupItemLayer(scaleFactor: scaleFactor, layoutRTL: layoutRTL)
                itemLayer.item = groupItem
                groupItem.itemLayer = itemLayer
                let group = ECSBGroup(pager: pager as? ECSBPager, forItemLayer: itemLayer, withItem: groupItem,
                                      scaleFactor: scaleFactor, layoutRTL: layoutRTL)
                group.scaleFactor = scaleFactor
                if let gridLayer = self.layer as? ECGridLayer {
                    group.maxItemsPerPage = UInt(gridLayer.rows * gridLayer.columns)
                }
                itemLayer.group = group
                itemLayer.eventDelegate = self  // REF-ARCH-006
                return itemLayer
            }
        }
        let itemLayer = ECSBItemLayer(scaleFactor: scaleFactor, layoutRTL: layoutRTL)
        itemLayer.item = gridItem
        gridItem?.itemLayer = itemLayer
        itemLayer.eventDelegate = self  // REF-ARCH-006
        return itemLayer
    }

    /// Gives each item layer its contents, the scale factor as the info (REF-GRID-014).
    func setContent(inLayers layers: NSArray, withDataRange range: NSRange, for layer: CALayer, usingScaleFactor scaleFactor: Float) {
        let info: NSDictionary = ["scaleFactor": NSNumber(value: scaleFactor)]
        var index = UInt(range.location)
        for case let itemLayer as ECSBGridItemSource in layers {
            itemLayer.setContent(fromDataSource: self, at: index, withItemInfo: info)
            index += 1
        }
    }

    // MARK: - ECSBGridDataSource

    /// `key` of the page's item at `index`, from the data source.
    func gridValue(forKey key: String, at index: UInt, withItemInfo info: NSDictionary?) -> AnyObject? {
        guard let items = item.items, index < items.count else { return nil }
        return (items[Int(index)] as? ECSBItem)?.value(forKey: key, withHandler: handler, andInfo: info)
    }

    /// Reloads its item layers' icons (REF-GRID-014).
    @objc func reloadItemContents() {
        (layer as? ECSBGridLayer)?.reloadItemContents(withDataSource: self)
    }

    /// Drops its item layers' icons (REF-GRID-015).
    @objc func purgeItemContents() {
        (layer as? ECSBGridLayer)?.purgeItemContents()
    }

    // MARK: - ECKeyboardNavigating

    /// Moves the pager's selected item within this page and returns YES when it set one
    /// (REF-KEYBOARD-002): Up and Down by one row of the grid layer, "back" and "forward" by one item
    /// in the page's order, Left and Right swapped right to left. Without a selected item, Up and
    /// "back" select the last item, Down and "forward" the first. It never leaves the page: past an
    /// end, with no items, with the selected item on another page, or for any other type, NO.
    @objc(navigate:withEvent:)
    func navigate(_ type: Int64, with event: ECEvent?) -> Bool {
        let pager = pager as? ECSBPager
        let selected = pager?.selectedItem
        let items = item.items
        let count = items?.count ?? 0
        var handled = false
        // The index of the selected item; nil without one or when it is not on this page.
        func selectedIndex(_ items: NSMutableArray) -> Int? {
            guard let selected else { return nil }
            let index = items.indexOfObjectIdentical(to: selected)
            return index == NSNotFound ? nil : index
        }
        let back = {
            guard let items, count != 0 else { return }
            if selected == nil {
                pager?.selectedItem = items.lastObject as? ECSBItem
            } else {
                guard let index = selectedIndex(items), index != 0 else { return }
                pager?.selectedItem = items[index - 1] as? ECSBItem
            }
            handled = true
        }
        let forward = {
            guard let items, count != 0 else { return }
            if selected == nil {
                pager?.selectedItem = items[0] as? ECSBItem
            } else {
                guard let index = selectedIndex(items), index < count - 1 else { return }
                pager?.selectedItem = items[index + 1] as? ECSBItem
            }
            handled = true
        }
        switch type {
        case 0:  // Up
            guard let items, count != 0 else { return false }
            if selected == nil {
                pager?.selectedItem = items.lastObject as? ECSBItem
            } else {
                guard let index = selectedIndex(items) else { return false }
                let above = index - ((layer as? ECGridLayer)?.columns ?? 0)
                guard above >= 0 else { return false }
                pager?.selectedItem = items[above] as? ECSBItem
            }
            handled = true
        case 1:  // Down
            guard let items, count != 0 else { return false }
            if selected == nil {
                pager?.selectedItem = items[0] as? ECSBItem
            } else {
                guard let index = selectedIndex(items) else { return false }
                let below = index + ((layer as? ECGridLayer)?.columns ?? 0)
                guard below < count else { return false }
                pager?.selectedItem = items[below] as? ECSBItem
            }
            handled = true
        case 2:  // Left
            layoutRTL ? forward() : back()
        case 3:  // Right
            layoutRTL ? back() : forward()
        default:
            break
        }
        return handled
    }

    // MARK: - ECEventHandlingDelegate

    // The item layers' events go to the pager's event handler (research paper §5.9).

    @objc(leftMouseDown:in:)
    func leftMouseDown(_ event: ECEvent, in layer: CALayer?) -> Bool {
        (pager as? ECSBPager)?.eventHandler?.leftMouseDown(event, inLayer: layer, ofPage: self) ?? false
    }

    @objc(leftMouseDragged:in:)
    func leftMouseDragged(_ event: ECEvent, in layer: CALayer?) -> Bool {
        (pager as? ECSBPager)?.eventHandler?.leftMouseDragged(event, inLayer: layer, ofPage: self) ?? false
    }

    @objc(leftMouseUp:in:)
    func leftMouseUp(_ event: ECEvent, in layer: CALayer?) -> Bool {
        (pager as? ECSBPager)?.eventHandler?.leftMouseUp(event, inLayer: layer, ofPage: self) ?? false
    }
}

import QuartzCore

/// A page of the main grid (REF-ARCH-005). It is its grid layer's layer source: the items of its page
/// item give the grid layer's item count and item layers (research paper §6.2).
@MainActor
@objc(ECSBPage)
class ECSBPage: ECPage, ECLayerSource, ECSBGridDataSource {
    @objc var handler: ECSBDataSource?
    @objc var item: ECSBPageItem
    var scaleFactor: Float
    var layoutRTL: Bool

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
}

import QuartzCore

/// A page of the main grid (REF-ARCH-005). It is its grid layer's layer source: the items of its page
/// item give the grid layer's item count and item layers (research paper §6.2).
@MainActor
@objc(ECSBPage)
class ECSBPage: ECPage, ECLayerSource {
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

    /// A folder gets an `ECSBGroupItemLayer`, anything else an `ECSBItemLayer`; the item and its layer
    /// point to each other.
    func makeLayer(for layer: CALayer, at index: UInt) -> CALayer? {
        var gridItem: ECSBItem?
        if let items = item.items, index < items.count {
            gridItem = items[Int(index)] as? ECSBItem
            let kind = handler?.value(forKey: "kind", ofItem: gridItem?.clientItem, withInfo: nil) as? String
            if kind == "group" {
                let itemLayer = ECSBGroupItemLayer(scaleFactor: scaleFactor, layoutRTL: layoutRTL)
                itemLayer.item = gridItem
                gridItem?.itemLayer = itemLayer
                return itemLayer
            }
        }
        let itemLayer = ECSBItemLayer(scaleFactor: scaleFactor, layoutRTL: layoutRTL)
        itemLayer.item = gridItem
        gridItem?.itemLayer = itemLayer
        return itemLayer
    }
}

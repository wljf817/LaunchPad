import QuartzCore

/// A grid of item layers: a clip layer holding the items layer, which holds one layer per item. The
/// layer source gives the item count and the item layers (REF-ARCH-007, research paper §6.2).
@MainActor
@objc(ECGridLayer)
class ECGridLayer: CALayer {
    weak var layerSource: ECLayerSource?
    var rows = 0
    var columns = 0
    @objc var rowHeight: UInt = 0
    @objc var columnWidth: UInt = 0
    /// Never set (REF-GRID-008).
    @objc let rowSpacing: UInt = 0
    @objc let columnSpacing: UInt = 0
    var numberOfItems: UInt = 0
    /// The items whose layers last got their contents (REF-GRID-014).
    var itemRange = NSRange(location: 0, length: 0)
    var _itemLayers = NSMutableArray(capacity: 0)
    @objc let clipLayer = CALayer()
    @objc let itemsLayer = CALayer()
    var scaleFactor: Float = 0
    var autoCalcSizes = false
    var layoutRTL = false

    @objc(initWithLayerSource:scaleFactor:layoutRTL:)
    init(layerSource: ECLayerSource?, scaleFactor: Float, layoutRTL: Bool) {
        super.init()
        self.layerSource = layerSource
        self.scaleFactor = scaleFactor
        clipLayer.masksToBounds = true
        addSublayer(clipLayer)
        clipLayer.addSublayer(itemsLayer)
        numberOfItems = layerSource?.numberOfItems(for: self) ?? 0
        self.layoutRTL = layoutRTL
    }

    @objc(initWithLayerSource:rows:columns:scaleFactor:layoutRTL:)
    convenience init(layerSource: ECLayerSource?, rows: Int, columns: Int, scaleFactor: Float, layoutRTL: Bool) {
        self.init(layerSource: layerSource, scaleFactor: scaleFactor, layoutRTL: layoutRTL)
        self.rows = rows
        self.columns = columns
        autoCalcSizes = true
    }

    @objc var itemLayers: NSMutableArray {
        _itemLayers
    }

    nonisolated override init(layer: Any) {
        super.init(layer: layer)
    }

    nonisolated required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// Sizes the clip and items layers to the grid layer, then lays out the item layers.
    @objc func layout() {
        let bounds = bounds
        // REF-GRID-008: the clip layer reaches 10 points higher.
        clipLayer.frame = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height + 10)
        itemsLayer.frame = bounds
        _layoutItemLayers()
    }

    /// Every grid layer of Launchpad is an `ECSBGridLayer`, which makes its item layers here.
    @objc func _layoutItemLayers() {}

    /// The index of `itemLayer`'s item: its position among the item layers plus the start of the item
    /// range; `NSNotFound` when it is not one of them (research paper §5.9).
    @objc(itemIndexForLayer:)
    func itemIndex(for itemLayer: CALayer?) -> UInt {
        guard let itemLayer else { return UInt(NSNotFound) }
        let position = _itemLayers.indexOfObjectIdentical(to: itemLayer)
        return position == NSNotFound ? UInt(NSNotFound) : UInt(itemRange.location + position)
    }
}

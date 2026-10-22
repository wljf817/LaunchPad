import QuartzCore

/// A grid of item layers: a clip layer holding the items layer, which holds one layer per item. The
/// layer source gives the item count and the item layers (REF-ARCH-007, research paper §6.2).
@MainActor
@objc(ECGridLayer)
class ECGridLayer: CALayer {
    weak var layerSource: ECLayerSource?
    var rows = 0
    var columns = 0
    var numberOfItems: UInt = 0
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

    /// The frames of the clip and items layers are grid geometry (1.3.2).
    @objc func layout() {
        _layoutItemLayers()
    }

    /// Every grid layer of Launchpad is an `ECSBGridLayer`, which makes its item layers here.
    @objc func _layoutItemLayers() {}
}

import QuartzCore

/// The grid of small app icons inside a folder icon (REF-ARCH-007, REF-GRID-013): a scroll layer with
/// a layer per item of its layer source, laid out in rows from the top, more than fit clipped below.
@MainActor
@objc(ECImageGridLayer)
final class ECImageGridLayer: CALayer {
    @objc weak var layerSource: ECLayerSource?
    var rowHeight: UInt = 0
    var columnWidth: UInt = 0
    var spacing: UInt = 0
    var rows = 0
    var columns = 0
    /// NSNotFound until asked from the layer source.
    var _numberOfItems = UInt(bitPattern: NSNotFound)
    @objc var numberOfItems: UInt { _numberOfItems }
    var itemLayers = NSMutableArray(capacity: 0)
    var itemRange = NSRange(location: 0, length: 0)
    var scaleFactor: Float = 0
    let itemsLayer = CAScrollLayer()
    var layoutRTL = false

    @objc(initWithLayerSource:rows:columns:spacing:scaleFactor:layoutRTL:)
    init(layerSource: ECLayerSource?, rows: Int, columns: Int, spacing: UInt, scaleFactor: Float, layoutRTL: Bool) {
        super.init()
        self.layerSource = layerSource
        self.scaleFactor = scaleFactor
        self.layoutRTL = layoutRTL
        self.rows = rows
        self.columns = columns
        self.spacing = spacing
        addSublayer(itemsLayer)
    }

    nonisolated override init(layer: Any) {
        super.init(layer: layer)
    }

    nonisolated required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc func setScaleFactor(_ scaleFactor: Float) {
        guard self.scaleFactor != scaleFactor else { return }
        self.scaleFactor = scaleFactor
        layout()
    }

    /// The items layer moved left and up by half the spacing, then the item layers.
    @objc func layout() {
        let bounds = bounds
        let half = CGFloat(Int32(Double(spacing) * 0.5))  // REF-GRID-013
        itemsLayer.frame = CGRect(x: bounds.minX - half, y: bounds.minY + half, width: bounds.width, height: bounds.height)
        _layoutItemLayers()
    }

    /// Makes or drops item layers to the number of items, sets their contents when the items changed,
    /// and places them row by row from the top (REF-GRID-013).
    @objc func _layoutItemLayers() {
        if numberOfItems == UInt(bitPattern: NSNotFound) {
            _numberOfItems = layerSource?.numberOfItems(for: self) ?? 0
        }
        let bounds = itemsLayer.bounds
        rowHeight = UInt(bitPattern: Int(Int32(bounds.height / CGFloat(rows))))
        columnWidth = UInt(bitPattern: Int(Int32(bounds.width / CGFloat(columns))))
        var count = UInt(itemLayers.count)
        if count < numberOfItems {
            while count < numberOfItems {
                if let itemLayer = layerSource?.makeLayer?(for: self) {
                    itemLayers.add(itemLayer)
                    itemLayer.bounds = CGRect(x: 0, y: 0, width: CGFloat(columnWidth &- spacing), height: CGFloat(rowHeight &- spacing))
                    itemsLayer.insertSublayer(itemLayer, at: 0)
                }
                count += 1
            }
        } else {
            while count > numberOfItems {
                let itemLayer = itemLayers.lastObject as? CALayer
                itemLayer?.removeFromSuperlayer()
                if let itemLayer {
                    itemLayers.remove(itemLayer)
                }
                count -= 1
            }
        }
        if itemRange.location != 0 || itemRange.length != Int(numberOfItems) {
            itemRange = NSRange(location: 0, length: Int(numberOfItems))
            let layers: NSArray = numberOfItems == UInt(itemLayers.count) ? itemLayers : itemLayers.subarray(with: itemRange) as NSArray
            layerSource?.setContent(inLayers: layers, withDataRange: itemRange, for: self, usingScaleFactor: scaleFactor)
        }
        let halfSpacing = Double(spacing) / 2
        let firstX = layoutRTL ? Double(bounds.maxX) - (halfSpacing + Double(columnWidth) / 2) : halfSpacing + Double(columnWidth) / 2
        var position = CGPoint(x: firstX, y: Double(Int(bounds.height)) - Double(rowHeight) / 2 - halfSpacing)
        let size = CGRect(x: 0, y: 0, width: CGFloat(columnWidth &- spacing), height: CGFloat(rowHeight &- spacing))
        var column = 0
        for case let itemLayer as CALayer in itemLayers {
            itemLayer.position = position
            itemLayer.bounds = size
            column += 1
            if column == columns {
                column = 0
                position.y -= CGFloat(rowHeight)
                position.x = firstX
            } else {
                position.x += layoutRTL ? -CGFloat(columnWidth) : CGFloat(columnWidth)
            }
        }
    }

    /// The items changed: count them again and set every item's contents.
    @objc(layerSourceInvalidated:)
    func layerSourceInvalidated(_ source: ECLayerSource?) {
        _numberOfItems = UInt(bitPattern: NSNotFound)
        itemRange = NSRange(location: 0, length: 0)
        layout()
    }

    @objc(itemLayerAtIndex:)
    func itemLayer(at index: UInt) -> CALayer? {
        index < UInt(itemLayers.count) ? itemLayers[Int(index)] as? CALayer : nil
    }

    /// The height of `bounds` divided among the rows, less the spacing (REF-GRID-006).
    @objc(iconSizeForBounds:withNumberOfRows:andColumns:withSpacing:)
    static func iconSize(forBounds bounds: CGRect, withNumberOfRows rows: UInt, andColumns columns: UInt,
                         withSpacing spacing: UInt) -> UInt {
        let rowHeight = UInt(bitPattern: Int(Int32(bounds.height))) / rows
        let size = Double(rowHeight) - Double(spacing)
        return size > 0 ? UInt(size) : 0
    }
}

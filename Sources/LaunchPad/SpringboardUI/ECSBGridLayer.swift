import QuartzCore

/// The grid layer of a page of the main grid (REF-ARCH-007).
@MainActor
@objc(ECSBGridLayer)
final class ECSBGridLayer: ECGridLayer {
    @objc(initWithLayerSource:scaleFactor:layoutRTL:)
    override init(layerSource: ECLayerSource?, scaleFactor: Float, layoutRTL: Bool) {
        super.init(layerSource: layerSource, scaleFactor: scaleFactor, layoutRTL: layoutRTL)
        clipLayer.masksToBounds = false
    }

    nonisolated override init(layer: Any) {
        super.init(layer: layer)
    }

    nonisolated required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// Sizes the cells from the items layer, makes an item layer for every item that has none, putting
    /// each in front of the items layer's sublayers, so they end up in reverse item order, and drops
    /// item layers from the end when there are too many (REF-GRID-003); then places the item layers
    /// row by row from the top (REF-GRID-008). Their contents come with 1.3.3.
    override func _layoutItemLayers() {
        let bounds = itemsLayer.bounds
        if autoCalcSizes {
            rowHeight = UInt(bitPattern: Int(Int32(bounds.height / CGFloat(rows))))
            columnWidth = UInt(bitPattern: Int(Int32(bounds.width / CGFloat(columns))))
        }
        var count = UInt(itemLayers.count)
        if count < numberOfItems {
            while count < numberOfItems {
                if let itemLayer = layerSource?.makeLayer!(for: self, at: count) {
                    itemLayers.add(itemLayer)
                    itemLayer.bounds = CGRect(x: 0, y: 0, width: CGFloat(columnWidth), height: CGFloat(rowHeight))
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
        let cell = CGRect(x: 0, y: 0, width: CGFloat(columnWidth), height: CGFloat(rowHeight))
        let firstX = layoutRTL ? bounds.maxX - CGFloat(columnWidth) / 2 : CGFloat(columnWidth) / 2
        var position = CGPoint(x: firstX, y: CGFloat(Int(bounds.height)) - CGFloat(rowHeight) * 0.5)
        var column = 0
        for (index, element) in itemLayers.enumerated() {
            let itemLayer = element as! CALayer
            if index < rows * columns {
                if !itemLayer.isHidden {
                    itemLayer.position = position
                    itemLayer.bounds = cell
                } else {
                    let disabled = disableActions()
                    itemLayer.isHidden = false
                    itemLayer.position = position
                    itemLayer.bounds = cell
                    if disabled {
                        CATransaction.setDisableActions(false)
                    }
                }
            } else {
                // Beyond a page: hidden.
                let disabled = disableActions()
                itemLayer.isHidden = true
                itemLayer.position = position
                itemLayer.bounds = cell
                if disabled {
                    CATransaction.setDisableActions(false)
                }
            }
            column += 1
            if column == columns {
                column = 0
                position.y -= CGFloat(rowHeight + rowSpacing)
                position.x = firstX
            } else {
                position.x += layoutRTL ? -CGFloat(columnWidth) : CGFloat(columnWidth)
            }
        }
    }

    /// The icon size and the folder's mini icon size for a cell of a grid of `bounds` (REF-GRID-006).
    @objc(calculateIconSize:miniIconSize:forBounds:andScaleFactor:withNumberOfRows:andColumns:)
    static func calculateIconSize(_ iconSize: UnsafeMutablePointer<UInt>, miniIconSize: UnsafeMutablePointer<UInt>,
                                  forBounds bounds: CGRect, andScaleFactor scaleFactor: Float,
                                  withNumberOfRows rows: UInt, andColumns columns: UInt) {
        ECSBItemLayer.calculateIconSize(iconSize, miniIconSize: miniIconSize,
                                        forBounds: cellBounds(bounds, rows: rows, columns: columns),
                                        andScaleFactor: scaleFactor)
    }

    /// The icon's frame in a cell of a grid of `bounds`, and the cell's bounds (REF-GRID-006).
    @objc(calculateIconFrame:itemBounds:forBounds:andScaleFactor:withNumberOfRows:andColumns:)
    static func calculateIconFrame(_ iconFrame: UnsafeMutablePointer<CGRect>, itemBounds: UnsafeMutablePointer<CGRect>,
                                   forBounds bounds: CGRect, andScaleFactor scaleFactor: Float,
                                   withNumberOfRows rows: UInt, andColumns columns: UInt) {
        let cell = cellBounds(bounds, rows: rows, columns: columns)
        itemBounds.pointee = cell
        ECSBItemLayer.calculateIconFrame(iconFrame, forBounds: cell, andScaleFactor: scaleFactor)
    }

    /// A cell: the bounds' whole width and height divided by the columns and rows (REF-GRID-006).
    private static func cellBounds(_ bounds: CGRect, rows: UInt, columns: UInt) -> CGRect {
        CGRect(x: 0, y: 0, width: CGFloat(UInt(bitPattern: Int(Int32(bounds.width))) / columns),
               height: CGFloat(UInt(bitPattern: Int(Int32(bounds.height))) / rows))
    }
}

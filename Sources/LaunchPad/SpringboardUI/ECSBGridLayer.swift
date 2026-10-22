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

    /// Makes an item layer for every item that has none, putting each in front of the items layer's
    /// sublayers, so they end up in reverse item order; drops item layers from the end when there are
    /// too many (REF-GRID-003). Their contents (1.3.3) and positions (1.3.2) come later.
    override func _layoutItemLayers() {
        var count = UInt(itemLayers.count)
        if count < numberOfItems {
            while count < numberOfItems {
                if let itemLayer = layerSource?.makeLayer!(for: self, at: count) {
                    itemLayers.add(itemLayer)
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
    }
}

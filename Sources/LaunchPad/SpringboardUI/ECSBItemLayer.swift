import LaunchPadPrivate
import QuartzCore

/// The layer of one item of a grid (REF-ARCH-007). The transform layer carries the item's scaling, the
/// jitter layer the edit-mode jitter; the icon and the name go into the jitter layer (1.3.3).
@MainActor
@objc(ECSBItemLayer)
class ECSBItemLayer: CALayer {
    @objc weak var item: ECSBItem?
    let transformLayer = CALayer()
    let jitterLayer = CALayer()
    var scaleFactor: Float = 0
    var layoutRTL = false

    @objc(initWithScaleFactor:layoutRTL:)
    init(scaleFactor: Float, layoutRTL: Bool) {
        super.init()
        self.scaleFactor = scaleFactor
        self.layoutRTL = layoutRTL
        jitterLayer.allowsGroupBlending = false
        transformLayer.sublayers = [jitterLayer]
        addSublayer(transformLayer)
    }

    nonisolated override init(layer: Any) {
        super.init(layer: layer)
    }

    nonisolated required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}

import QuartzCore

/// The layer of a folder in a grid (REF-ARCH-007). Its folder icon's own layers come in 1.3.3.
@MainActor
@objc(ECSBGroupItemLayer)
final class ECSBGroupItemLayer: ECSBItemLayer {
    @objc(initWithScaleFactor:layoutRTL:)
    override init(scaleFactor: Float, layoutRTL: Bool) {
        super.init(scaleFactor: scaleFactor, layoutRTL: layoutRTL)
    }

    nonisolated override init(layer: Any) {
        super.init(layer: layer)
    }

    nonisolated required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}

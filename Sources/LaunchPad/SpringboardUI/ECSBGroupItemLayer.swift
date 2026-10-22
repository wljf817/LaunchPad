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

    /// The size, in pixels, of an app's icon inside a folder icon of `bounds` (REF-GRID-006).
    @objc(miniIconSizeForBounds:andScaleFactor:)
    static func miniIconSize(forBounds bounds: CGRect, andScaleFactor scaleFactor: Float) -> UInt {
        // REF-GRID-006: inset by a tenth, the origin moved by 2 (1 up to 100 points) and 1.
        let inset = CGFloat(Int32(bounds.width * 0.1))
        var grid = bounds.insetBy(dx: inset, dy: inset)
        grid.origin.y += 1
        grid.origin.x += bounds.width > 100 ? 2 : 1
        // REF-GRID-006: a 3 × 3 grid with spacing 4; 1 to 32 points.
        let size = Int32(truncatingIfNeeded: ECImageGridLayer.iconSize(forBounds: grid, withNumberOfRows: 3, andColumns: 3,
                                                                       withSpacing: 4))
        return UInt(Float(max(min(size, 32), 1)) * scaleFactor)
    }
}

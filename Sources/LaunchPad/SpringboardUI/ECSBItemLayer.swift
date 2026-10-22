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

    /// The icon size and the folder's mini icon size, in pixels, for a cell of `bounds`
    /// (REF-GRID-006).
    @objc(calculateIconSize:miniIconSize:forBounds:andScaleFactor:)
    static func calculateIconSize(_ iconSize: UnsafeMutablePointer<UInt>, miniIconSize: UnsafeMutablePointer<UInt>,
                                  forBounds bounds: CGRect, andScaleFactor scaleFactor: Float) {
        let points = UInt(iconPoints(forCell: bounds).size)
        iconSize.pointee = UInt(Float(points) * scaleFactor)
        miniIconSize.pointee = ECSBGroupItemLayer.miniIconSize(
            forBounds: CGRect(x: 0, y: 0, width: CGFloat(points), height: CGFloat(points)), andScaleFactor: scaleFactor)
    }

    /// The icon's frame in a cell of `bounds`: centred, above the name (REF-GRID-006).
    @objc(calculateIconFrame:forBounds:andScaleFactor:)
    static func calculateIconFrame(_ iconFrame: UnsafeMutablePointer<CGRect>, forBounds bounds: CGRect,
                                   andScaleFactor scaleFactor: Float) {
        let (size, nameHeight) = iconPoints(forCell: bounds)
        let points = UInt(size)
        let pixels = CGFloat(UInt(Float(points) * scaleFactor))
        // REF-GRID-006: an eighth of the cell's height, at most 20, below the icon.
        let gap = min((bounds.height * 0.125).rounded(.up), 20)
        iconFrame.pointee = CGRect(x: CGFloat(Int32(bounds.width * 0.5 - CGFloat(points >> 1))), y: gap + nameHeight,
                                   width: pixels, height: pixels)
    }

    /// The icon's size in points for a cell, and the height the name takes below it: the cell's
    /// smaller side less the name's line and fixed gaps, rounded down to a multiple of 8, between 20
    /// and 128 (REF-GRID-006).
    private static func iconPoints(forCell bounds: CGRect) -> (size: CGFloat, nameHeight: CGFloat) {
        let environment = ECSBEnvironment.shared
        // REF-GRID-006: the name's line plus 11.
        let nameHeight = textHeight(environment.labelFont, size: CGFloat(environment.labelFontSize)) + 11
        let available = min(bounds.width, bounds.height) - (nameHeight + 24)  // REF-GRID-006
        let whole = UInt32(truncatingIfNeeded: available > 0 ? UInt64(available) : 0)
        // REF-GRID-006: at most 128, a multiple of 8; 1 below 8; at least 20.
        var size = whole & 0x7fff_ff80 != 0 ? 128 : whole & 0x7fff_fff8
        if Int32(bitPattern: whole) < 8 {
            size = 1
        }
        return (max(CGFloat(size), 20), nameHeight)
    }
}

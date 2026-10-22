import QuartzCore

/// The grid of small app icons inside a folder icon (REF-ARCH-007). So far only its icon size is used,
/// for the folder's mini icon size (REF-GRID-006); the layer itself comes with 1.3.3.
@MainActor
@objc(ECImageGridLayer)
final class ECImageGridLayer: CALayer {
    /// The height of `bounds` divided among the rows, less the spacing (REF-GRID-006).
    @objc(iconSizeForBounds:withNumberOfRows:andColumns:withSpacing:)
    static func iconSize(forBounds bounds: CGRect, withNumberOfRows rows: UInt, andColumns columns: UInt,
                         withSpacing spacing: UInt) -> UInt {
        let rowHeight = UInt(bitPattern: Int(Int32(bounds.height))) / rows
        let size = Double(rowHeight) - Double(spacing)
        return size > 0 ? UInt(size) : 0
    }
}

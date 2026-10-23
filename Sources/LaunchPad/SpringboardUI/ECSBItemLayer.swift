import LaunchPadPrivate
import QuartzCore

/// The layer of one item of a grid (REF-ARCH-007). The transform layer carries the item's scaling, the
/// jitter layer the edit-mode jitter; the icon and the name are in the jitter layer (REF-GRID-010).
@MainActor
@objc(ECSBItemLayer)
class ECSBItemLayer: CALayer, ECSBGridItemSource {
    @objc weak var item: ECSBItem?
    let transformLayer = CALayer()
    let jitterLayer = CALayer()
    @objc let imageLayer = CALayer()
    /// Set once at initialization; copies made by Core Animation share it.
    @objc nonisolated(unsafe) let labelLayer: ECSBLabelLayer
    /// Made by `-_makeBackdropLayer`, for folders (REF-GRID-013).
    var _backdropLayer: CALayer?
    var tintLayer: CALayer?
    var scaleFactor: Float = 0
    var layoutRTL = false
    /// Compared by identity with a new title, as the original does.
    var _title: NSString?
    var magnified = false
    /// Set while the contents are being set, so that the layout runs once after them.
    var internalDisableLayout = false
    var _visible = false

    @objc(initWithScaleFactor:layoutRTL:)
    init(scaleFactor: Float, layoutRTL: Bool) {
        labelLayer = ECSBLabelLayer(string: "", andScaleFactor: scaleFactor)
        super.init()
        self.scaleFactor = scaleFactor
        self.layoutRTL = layoutRTL
        imageLayer.contentsGravity = .resizeAspect  // REF-GRID-010
        labelLayer.contentsCenter = CGRect(x: 0.5, y: 0.5, width: 0, height: 0)  // REF-GRID-010
        jitterLayer.sublayers = [imageLayer, labelLayer]
        jitterLayer.allowsGroupBlending = false
        transformLayer.sublayers = [jitterLayer]
        addSublayer(transformLayer)
    }

    nonisolated override init(layer: Any) {
        labelLayer = (layer as! ECSBItemLayer).labelLayer
        super.init(layer: layer)
    }

    nonisolated required init?(coder: NSCoder) {
        nil
    }

    @objc var backdropLayer: CALayer? { _backdropLayer }

    @objc var isGroupItem: Bool { false }

    // MARK: - Visibility and purging (REF-GRID-015)

    @objc var visible: Bool { _visible }

    /// The flagged state of new and beta items, which the original changes here, comes with phase 6.
    @objc(setVisible:)
    func setVisible(_ visible: Bool) {
        guard _visible != visible else { return }
        _visible = visible
    }

    /// Drops the icon; the name stays.
    @objc func purgeItemContents() {
        let disabled = disableActions()
        imageLayer.contents = nil
        if disabled {
            CATransaction.setDisableActions(false)
        }
    }

    // MARK: - Contents (REF-GRID-014)

    /// The icon is the icon layer's contents; setting it lays the item out.
    @objc var icon: AnyObject? {
        get { imageLayer.contents as AnyObject? }
        set {
            let disabled = disableActions()
            imageLayer.contents = newValue
            layout()
            if disabled {
                CATransaction.setDisableActions(false)
            }
        }
    }

    /// The name; a new one (by identity) is drawn at once.
    @objc var title: NSString? {
        get { _title }
        set {
            guard _title !== newValue else { return }
            _title = newValue
            _setTitle(newValue)
        }
    }

    @objc(_setTitle:)
    func _setTitle(_ title: NSString?) {
        let disabled = disableActions()
        labelLayer.string = title
        layout()
        labelLayer.textLayer.display()
        if disabled {
            CATransaction.setDisableActions(false)
        }
    }

    /// Asks the data source for the icon, with the icon layer's height as the size, and the name, then
    /// lays out once. The other keys (progress, status and the flags) come with later phases.
    @objc(setContentFromDataSource:atIndex:withItemInfo:)
    func setContent(fromDataSource dataSource: ECSBGridDataSource, at index: UInt, withItemInfo info: NSDictionary?) {
        let height = Int(saturatingInt64(imageLayer.frame.height))
        let scale = (info?["scaleFactor"] as? NSNumber)?.floatValue ?? 1
        // REF-GRID-014: the icon layer's height, 128 when below 2.
        let iconInfo: NSDictionary = ["iconSize": NSNumber(value: Int32(truncatingIfNeeded: height < 2 ? 128 : height)),
                                      "scaleFactor": NSNumber(value: scale)]
        internalDisableLayout = true
        icon = dataSource.gridValue(forKey: "icon", at: index, withItemInfo: iconInfo)
        title = dataSource.gridValue(forKey: "title", at: index, withItemInfo: info) as? NSString
        internalDisableLayout = false
        layout()
    }

    /// Reloads only the icon, asking with the icon layer's height in pixels (REF-GRID-014).
    @objc(reloadItemContentsWithDataSource:atIndex:)
    func reloadItemContents(withDataSource dataSource: ECSBGridDataSource, at index: UInt) {
        let height = Int(saturatingInt64(imageLayer.frame.height))
        // REF-GRID-014: the icon layer's height, 128 when below 2, times the scale factor.
        let pixels = Int32(truncatingIfNeeded: saturatingInt64(Double(scaleFactor * Float(height < 2 ? 128 : height))))
        let info: NSDictionary = ["iconSize": NSNumber(value: pixels)]
        let disabled = disableActions()
        icon = dataSource.gridValue(forKey: "icon", at: index, withItemInfo: info)
        if disabled {
            CATransaction.setDisableActions(false)
        }
    }

    // MARK: - Layout (REF-GRID-010)

    /// Lays out the transform and jitter layers, the name below the icon and, for folders, the
    /// backdrop and tint layers around the icon. The marks that only other states have come with
    /// later phases.
    @objc func layout() {
        guard !internalDisableLayout else { return }
        let bounds = bounds
        if !magnified {
            transformLayer.frame = bounds
        }
        jitterLayer.frame = bounds
        let preferred = labelLayer.preferredFrameSize()
        // REF-GRID-010: the name at most 12 points narrower than the cell, centered.
        let available = bounds.width - 12
        let nameWidth = preferred.width <= available ? preferred.width : available
        labelLayer.textLayer.alignmentMode = .center
        // REF-GRID-010: the name an eighth of the cell's height, at most 20, above the bottom.
        let nameBottom = min((bounds.height * 0.125).rounded(.up), 20)
        labelLayer.frame = CGRect(x: Self.centered(bounds.width * 0.5 - nameWidth * 0.5, odd: Int32(nameWidth) & 1 != 0),
                                  y: nameBottom, width: nameWidth, height: preferred.height)
        labelLayer.layout()
        // REF-GRID-010: the icon's points, as +calculateIconSize: but less the name's preferred height.
        let points = Self.iconPoints(min(bounds.width, bounds.height) - (preferred.height + 24))
        imageLayer.frame = CGRect(x: Self.centered(bounds.width * 0.5 - CGFloat(points >> 1), odd: points & 1 != 0),
                                  y: nameBottom + preferred.height, width: CGFloat(points), height: CGFloat(points))
        if let backdrop = _backdropLayer, let tintLayer {
            let frame = _backdropFrame()
            // REF-GRID-010: rounded to the nearest point.
            let radius = (imageLayer.frame.height * 0.15625).rounded()
            backdrop.cornerRadius = radius
            tintLayer.cornerRadius = radius
            backdrop.frame = frame
            tintLayer.frame = frame
        }
    }

    /// A centered origin: truncated for an even width, rounded half away from zero for an odd one.
    private static func centered(_ value: CGFloat, odd: Bool) -> CGFloat {
        odd ? value.rounded() : value.rounded(.towardZero)
    }

    /// 128 at least 128, otherwise down to a multiple of 8; 1 below 8; at least 20 (REF-GRID-010).
    private static func iconPoints(_ available: CGFloat) -> UInt {
        let whole = UInt32(truncatingIfNeeded: available > 0 ? UInt64(available) : 0)
        var size = whole & 0x7fff_ff80 != 0 ? 128 : whole & 0x7fff_fff8
        if Int32(bitPattern: whole) < 8 {
            size = 1
        }
        return UInt(max(size, 20))
    }

    // MARK: - Folders' backdrop (REF-GRID-013)

    /// The backdrop and the tint layer of a folder icon, both transparent at first.
    @objc func _makeBackdropLayer() {
        let backdrop = CALayer()
        backdrop.backgroundColor = CGColor(gray: 0.9686, alpha: 0.5)  // REF-GRID-013
        backdrop.opacity = 0
        backdrop.cornerRadius = 24  // REF-GRID-013
        backdrop.cornerCurve = .continuous
        _backdropLayer = backdrop
        let tint = CALayer()
        tint.name = "tint"
        tint.backgroundColor = CGColor(gray: 0.9412, alpha: 1)  // REF-GRID-013
        tint.compositingFilter = kCAFilterDarkenBlendMode
        tint.cornerRadius = 24  // REF-GRID-013
        tint.opacity = 0
        tintLayer = tint
    }

    /// The icon frame inset by `-_backdropInsetForFrame:`.
    @objc func _backdropFrame() -> CGRect {
        let inset = _backdropInsetForFrame(imageLayer.frame)
        return imageLayer.frame.insetBy(dx: inset, dy: inset)
    }

    /// 5, 7, 10 or 12 points by the icon's height (REF-GRID-010).
    @objc(_backdropInsetForFrame:)
    func _backdropInsetForFrame(_ frame: CGRect) -> CGFloat {
        let height = imageLayer.frame.height
        if height <= 60 {
            return 5
        }
        if height <= 80 {
            return 7
        }
        return height < 128 ? 10 : 12
    }

    // MARK: - Icon sizes (REF-GRID-006)

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
        return (CGFloat(iconPoints(available)), nameHeight)
    }
}

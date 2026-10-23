import QuartzCore

/// The layer of a folder in a grid (REF-ARCH-007): the item layer's structure with a backdrop, a tint
/// and a grid of mini icons in place of an icon (REF-GRID-013).
@MainActor
@objc(ECSBGroupItemLayer)
final class ECSBGroupItemLayer: ECSBItemLayer {
    @objc var groupShown = false
    var _group: ECSBGroup?
    /// Set once at initialization; copies made by Core Animation share it.
    @objc nonisolated(unsafe) let miniGridLayer: ECImageGridLayer

    @objc(initWithScaleFactor:layoutRTL:)
    override init(scaleFactor: Float, layoutRTL: Bool) {
        // REF-GRID-013: 3 rows, 3 columns, spacing 4.
        miniGridLayer = ECImageGridLayer(layerSource: nil, rows: 3, columns: 3, spacing: 4, scaleFactor: scaleFactor,
                                         layoutRTL: layoutRTL)
        super.init(scaleFactor: scaleFactor, layoutRTL: layoutRTL)
        imageLayer.contents = nil
        _makeBackdropLayer()
        if let backdrop = _backdropLayer, let tintLayer {
            jitterLayer.sublayers = [backdrop, tintLayer, imageLayer, labelLayer]
            backdrop.opacity = 1  // REF-GRID-013
        }
        groupShown = false
        miniGridLayer.allowsHitTesting = false
        miniGridLayer.masksToBounds = true
        jitterLayer.addSublayer(miniGridLayer)
    }

    nonisolated override init(layer: Any) {
        miniGridLayer = (layer as! ECSBGroupItemLayer).miniGridLayer
        super.init(layer: layer)
    }

    nonisolated required init?(coder: NSCoder) {
        nil
    }

    @objc override var isGroupItem: Bool { true }

    @objc var group: ECSBGroup? {
        get { _group }
        set {
            guard _group !== newValue else { return }
            _group = newValue
            miniGridLayer.layerSource = newValue
        }
    }

    /// The name; the mini icons come from the mini icon grid (REF-GRID-014). Progress and status
    /// come with phase 6.
    @objc(setContentFromDataSource:atIndex:withItemInfo:)
    override func setContent(fromDataSource dataSource: ECSBGridDataSource, at index: UInt, withItemInfo info: NSDictionary?) {
        title = dataSource.gridValue(forKey: "title", at: index, withItemInfo: info) as? NSString
    }

    /// Sets every mini icon again; an open folder's pages are reloaded by the folder (phase 5).
    @objc(reloadItemContentsWithDataSource:atIndex:)
    override func reloadItemContents(withDataSource dataSource: ECSBGridDataSource, at index: UInt) {
        let disabled = disableActions()
        miniGridLayer.layerSourceInvalidated(_group)
        if disabled {
            CATransaction.setDisableActions(false)
        }
    }

    /// A mini icon that changed: the layer of that app on the folder's first page (REF-GRID-014).
    @objc(setValue:forKey:ofItem:)
    func setValue(_ value: AnyObject?, forKey key: String, ofItem item: ECSBItem?) {
        guard key == "miniIcon" else { return }
        guard let pages = _group?.item?.items, pages.count != 0,
              let apps = (pages[0] as? ECSBItem)?.items, let item else { return }
        let index = apps.index(of: item)
        guard index != NSNotFound, let miniIcon = miniGridLayer.itemLayer(at: UInt(index)) else { return }
        miniIcon.contents = value
    }

    /// The item layer's layout, then the mini icon grid inside the backdrop, reloaded (REF-GRID-013).
    @objc override func layout() {
        super.layout()
        let inset = _backdropInsetForFrame(imageLayer.frame)
        let backdrop = imageLayer.frame.insetBy(dx: inset, dy: inset)
        let gridInset = CGFloat(Int32(backdrop.width * 0.1))  // REF-GRID-013
        miniGridLayer.frame = backdrop.insetBy(dx: gridInset, dy: gridInset)
        miniGridLayer.layerSourceInvalidated(_group)
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

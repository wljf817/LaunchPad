import QuartzCore

/// A folder of the grid (REF-ARCH-005, research paper §11). Made with the folder's item layer; it is
/// the layer source of the folder icon's mini icon grid. What only an open folder has (its layer, its
/// pager and page) comes with phase 5.
@MainActor
@objc(ECSBGroup)
final class ECSBGroup: NSObject, ECLayerSource, ECLayerSourceClient {
    @objc private(set) var pager: ECSBPager?
    @objc weak var itemLayer: ECSBGroupItemLayer?
    var _item: ECSBGroupItem?
    var scaleFactor: Float = 0
    var isNewGroup = false
    var layoutRTL = false
    @objc var maxItemsPerPage: UInt = 0

    @objc(initWithPager:forItemLayer:withItem:scaleFactor:layoutRTL:)
    init(pager: ECSBPager?, forItemLayer itemLayer: ECSBGroupItemLayer?, withItem item: ECSBGroupItem?,
         scaleFactor: Float, layoutRTL: Bool) {
        self.pager = pager
        self.itemLayer = itemLayer
        _item = item
        isNewGroup = false
        self.scaleFactor = scaleFactor
        self.layoutRTL = layoutRTL
        super.init()
        item?.group = self
    }

    @objc var item: ECSBGroupItem? {
        get { _item }
        set {
            guard _item !== newValue else { return }
            _item = newValue
            _item?.group = self
        }
    }

    @objc func setScaleFactor(_ scaleFactor: Float) {
        if self.scaleFactor != scaleFactor {
            self.scaleFactor = scaleFactor
        }
    }

    /// The apps of the folder's first page.
    private var firstPageItems: NSArray? {
        guard let pages = _item?.items, pages.count != 0 else { return nil }
        return (pages[0] as? ECSBItem)?.items
    }

    // MARK: - ECLayerSource (the mini icon grid, REF-GRID-013)

    func numberOfItems(for layer: CALayer) -> UInt {
        UInt(firstPageItems?.count ?? 0)
    }

    /// A plain layer per mini icon.
    func makeLayer(for layer: CALayer) -> CALayer? {
        guard layer is ECImageGridLayer else { return nil }
        let miniIcon = CALayer()
        miniIcon.contentsGravity = .resizeAspect  // REF-GRID-013
        miniIcon.contentsScale = CGFloat(scaleFactor)
        return miniIcon
    }

    /// Each mini icon layer gets the `miniIcon` of the first page's app at its index, asked with the
    /// layer's height as the size (REF-GRID-013).
    func setContent(inLayers layers: NSArray, withDataRange range: NSRange, for layer: CALayer, usingScaleFactor scaleFactor: Float) {
        guard layer is ECImageGridLayer else { return }
        let disabled = disableActions()
        var index = range.location
        for case let miniIcon as CALayer in layers {
            let app = firstPageItems?[index] as? ECSBItem
            let height = miniIcon.frame.height
            // REF-GRID-013: 32 when the layer has no height yet.
            let info: NSDictionary = ["miniIconSize": NSNumber(value: Int32(truncatingIfNeeded: saturatingInt64(height <= 1 ? 32 : height))),
                                      "scaleFactor": NSNumber(value: scaleFactor)]
            miniIcon.contents = app?.value(forKey: "miniIcon", withHandler: pager?.handler, andInfo: info)
            index += 1
        }
        if disabled {
            CATransaction.setDisableActions(false)
        }
    }

    // MARK: - ECLayerSourceClient

    func layerSourceInvalidated(_ source: ECLayerSource?) {
        let disabled = disableActions()
        itemLayer?.layout()
        if disabled {
            CATransaction.setDisableActions(false)
        }
    }
}

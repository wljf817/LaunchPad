import QuartzCore

// The protocols between the controller, the grid components and their layers (REF-ARCH-006,
// REF-ARCH-013). Selectors and optionality are the original's; only the methods the grid tree uses
// are declared. Optional methods are sent without checking, as the original does.

/// The controller as the grid's data source.
@MainActor
@objc(ECSBDataSource)
protocol ECSBDataSource: NSObjectProtocol {
    /// `items`: the model children of `item` (the layout root's when `item` is nil); `kind`: `page`,
    /// `group` or `item`.
    @objc(valueForKey:ofItem:withInfo:)
    func value(forKey key: String, ofItem item: AnyObject?, withInfo info: AnyObject?) -> AnyObject?
}

/// The source of a pager's pages.
@MainActor
@objc(ECPagerSource)
protocol ECPagerSource: NSObjectProtocol {
    @objc(numberOfPagesForPager:)
    func numberOfPages(for pager: ECPager) -> UInt

    @objc(makePageForPager:atIndex:)
    func makePage(for pager: ECPager, at index: UInt) -> ECPage?

    @objc(pageItemsForPager:)
    func pageItems(for pager: ECPager) -> NSArray?

    @objc(layoutPage:forPager:)
    optional func layoutPage(_ page: ECPage, for pager: ECPager)
}

/// The source of a grid layer's item layers and their contents.
@MainActor
@objc(ECLayerSource)
protocol ECLayerSource: NSObjectProtocol {
    @objc(numberOfItemsForLayer:)
    func numberOfItems(for layer: CALayer) -> UInt

    @objc(setContentInLayers:withDataRange:forLayer:usingScaleFactor:)
    func setContent(inLayers layers: NSArray, withDataRange range: NSRange, for layer: CALayer, usingScaleFactor scaleFactor: Float)

    @objc(makeLayerForLayer:)
    optional func makeLayer(for layer: CALayer) -> CALayer?

    @objc(makeLayerForLayer:atIndex:)
    optional func makeLayer(for layer: CALayer, at index: UInt) -> CALayer?
}

/// Told by a layer source that its items changed.
@MainActor
@objc(ECLayerSourceClient)
protocol ECLayerSourceClient: NSObjectProtocol {
    @objc(layerSourceInvalidated:)
    func layerSourceInvalidated(_ source: ECLayerSource?)
}

/// What an item layer asks for its contents: a page or a folder.
@MainActor
@objc(ECSBGridDataSource)
protocol ECSBGridDataSource: NSObjectProtocol {
    @objc(gridValueForKey:atIndex:withItemInfo:)
    func gridValue(forKey key: String, at index: UInt, withItemInfo info: NSDictionary?) -> AnyObject?
}

/// An item layer that takes its contents from a grid data source.
@MainActor
@objc(ECSBGridItemSource)
protocol ECSBGridItemSource: NSObjectProtocol {
    @objc(setContentFromDataSource:atIndex:withItemInfo:)
    func setContent(fromDataSource dataSource: ECSBGridDataSource, at index: UInt, withItemInfo info: NSDictionary?)

    @objc var isGroupItem: Bool { get }
}

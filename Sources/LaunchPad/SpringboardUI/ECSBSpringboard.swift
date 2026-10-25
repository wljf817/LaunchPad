import os
import QuartzCore

/// The main grid: the item tree that mirrors the layout, and the pager that shows its pages
/// (REF-ARCH-005, REF-ARCH-006, research paper §6). It talks to the controller only through the
/// data source protocol (REF-ARCH-013).
@MainActor
@objc(ECSBSpringboard)
final class ECSBSpringboard: NSObject, ECPagerSource, ECSBGridActionHandling, ECEventHandling {
    /// The controller. It holds this object too; neither is released (REF-ARCH-006).
    @objc var handler: ECSBDataSource
    let item = ECSBSpringboardItem()
    var numberOfRowsPerPage: UInt
    var numberOfColumnsPerPage: UInt
    var _pager: ECSBPager!
    /// Handles the presses, drags and releases on the items of every pager (research paper §5.9).
    var _eventHandler: ECSBEventHandler!
    var scaleFactor: Float
    var layoutRTL: Bool
    var _visible = false

    @objc(initWithHandler:numberOfRowsPerPage:numberOfColumnsPerPage:scaleFactor:layoutRTL:)
    init(handler: ECSBDataSource, numberOfRowsPerPage: UInt, numberOfColumnsPerPage: UInt, scaleFactor: Float,
         layoutRTL: Bool) {
        self.scaleFactor = scaleFactor
        self.layoutRTL = layoutRTL
        self.handler = handler
        self.numberOfRowsPerPage = numberOfRowsPerPage
        self.numberOfColumnsPerPage = numberOfColumnsPerPage
        super.init()
        _eventHandler = ECSBEventHandler(springboard: self)
        _pager = ECSBPager(pagerSource: self, scaleFactor: scaleFactor, layoutRTL: layoutRTL)
        _pager.gridActionHandler = self
        _pager.handler = handler
        _pager.eventHandler = _eventHandler
    }

    /// The grid action on the item at `index` of the sending page: the controller acts on the item's
    /// model object (REF-LAUNCH-003). A folder's page as the sender comes with phase 5.
    @objc(performGridActionAtIndex:withEvent:sender:)
    func performGridAction(at index: UInt, with event: ECEvent?, sender: AnyObject?) {
        var gridItem: ECSBItem?
        if let page = sender as? ECSBPage, let items = page.item.items, index < items.count {
            gridItem = items[Int(index)] as? ECSBItem
        }
        guard let gridItem else { return }
        (handler as? ECSBActionHandling)?.performAction(forItem: gridItem.clientItem, with: event, sender: self)
    }

    /// The model object's icon layer's frame in the root layer's coordinates; zero when it has no
    /// item layer (REF-LAUNCH-002).
    @objc(globalBoundsOfIconForItem:)
    func globalBoundsOfIcon(forItem clientItem: AnyObject?) -> CGRect {
        guard let imageLayer = item(forClientItem: clientItem)?.itemLayer?.imageLayer,
              let superlayer = imageLayer.superlayer else { return .zero }
        return superlayer.convert(imageLayer.frame, to: nil)
    }

    /// A click on the grid that was not on an item: passed on to the controller (REF-OVERLAY-010).
    @objc(cancelGridActionWithEvent:sender:)
    func cancelGridAction(with event: ECEvent?, sender: AnyObject?) {
        if let handler = handler as? ECSBActionHandling,
           handler.responds(to: #selector(ECSBActionHandling.cancelAction(with:sender:))) {
            handler.cancelAction?(with: event, sender: sender)
        }
    }

    @objc var pager: ECSBPager {
        _pager
    }

    /// The pager's (REF-PAGING-001).
    @objc var currentPageIndex: UInt {
        get { _pager.currentPageIndex }
        set { _pager.currentPageIndex = newValue }
    }

    /// The pager's page at the current page index; nil without pages or past the end.
    @objc var currentPage: ECPage? {
        let pages = _pager.pages
        guard pages.count != 0, _pager.currentPageIndex < UInt(pages.count) else { return nil }
        return pages[Int(_pager.currentPageIndex)] as? ECPage
    }

    /// The pager's (REF-PAGING-003).
    @objc var pagerControlVisibility: Int {
        get { _pager.pagerControlVisibility }
        set { _pager.pagerControlVisibility = newValue }
    }

    @objc var eventHandler: ECSBEventHandler {
        _eventHandler
    }

    @objc var editing: Bool {
        get { pager.editing }
        set { pager.editing = newValue }
    }

    @objc var layer: ECSBLayer {
        pager.layer as! ECSBLayer
    }

    // The margins and the zoom factor are the pager layer's (REF-GRID-004, REF-GRID-005).

    @objc var leftMargin: CGFloat {
        get { pager.layer.leftMargin }
        set { pager.layer.leftMargin = newValue }
    }

    @objc var rightMargin: CGFloat {
        get { pager.layer.rightMargin }
        set { pager.layer.rightMargin = newValue }
    }

    @objc var topMargin: CGFloat {
        get { pager.layer.topMargin }
        set { pager.layer.topMargin = newValue }
    }

    @objc var bottomMargin: CGFloat {
        get { pager.layer.bottomMargin }
        set { pager.layer.bottomMargin = newValue }
    }

    @objc var zoomFactor: CGFloat {
        get { layer.zoomFactor }
        set { layer.zoomFactor = newValue }
    }

    /// The main grid's icon sizes, worked out by the pager layer's class (REF-GRID-006).
    @objc(calculateIconSize:miniIconSize:forBounds:andScaleFactor:usingLeftMargin:rightMargin:topMargin:bottomMargin:zoomStyle:zoomFactor:withNumberOfRows:andColumns:)
    static func calculateIconSize(_ iconSize: UnsafeMutablePointer<UInt>, miniIconSize: UnsafeMutablePointer<UInt>,
                                  forBounds bounds: CGRect, andScaleFactor scaleFactor: Float,
                                  usingLeftMargin leftMargin: CGFloat, rightMargin: CGFloat, topMargin: CGFloat,
                                  bottomMargin: CGFloat, zoomStyle: Int, zoomFactor: CGFloat,
                                  withNumberOfRows rows: UInt, andColumns columns: UInt) {
        ECSBLayer.calculateIconSize(iconSize, miniIconSize: miniIconSize, forBounds: bounds, andScaleFactor: scaleFactor,
                                    usingLeftMargin: leftMargin, rightMargin: rightMargin, topMargin: topMargin,
                                    bottomMargin: bottomMargin, zoomStyle: zoomStyle, zoomFactor: zoomFactor,
                                    withNumberOfRows: rows, andColumns: columns)
    }

    /// Rebuilds the page items from the layout and makes the pager drop and remake its pages.
    @objc func invalidate() {
        let disabled = disableActions()
        var pageItems: NSMutableArray?
        if let pages = handler.value(forKey: "items", ofItem: nil, withInfo: nil) as? NSArray {
            pageItems = NSMutableArray(capacity: pages.count)
            for page in pages {
                let pageItem = ECSBPageItem()
                pageItem.parent = item
                pageItem.clientItem = page as AnyObject
                pageItems?.add(pageItem)
            }
        }
        item.items = pageItems
        pager.invalidate()
        if disabled {
            CATransaction.setDisableActions(false)
        }
    }

    /// The item that stands for a model object, searched depth first from the root item.
    @objc(itemForClientItem:)
    func item(forClientItem clientItem: AnyObject?) -> ECSBItem? {
        item.item(forClientItem: clientItem)
    }

    /// A model object's value changed (REF-GRID-014): a folder's item layer takes it when the item
    /// is in a folder; the item's own layer takes it with key-value coding.
    @objc(setValue:forKey:ofItem:)
    func setValue(_ value: AnyObject?, forKey key: String, ofItem clientItem: AnyObject?) {
        guard let gridItem = item(forClientItem: clientItem) else { return }
        let itemLayer = gridItem.itemLayer
        if let groupItem = gridItem.parent?.parent as? ECSBGroupItem {
            groupItem.groupItemLayer?.setValue(value, forKey: key, ofItem: gridItem)
        }
        itemLayer?.setValue(value, forKey: key)
    }

    @objc(reloadItemContents:)
    func reloadItemContents(_ exceptCurrentPage: Bool) {
        pager.reloadItemContents(exceptCurrentPage)
    }

    /// Drops the item layers' icon contents (REF-GRID-015).
    @objc(purgeItemContents:)
    func purgeItemContents(_ exceptCurrentPage: Bool) {
        pager.purgeItemContents(exceptCurrentPage)
    }

    @objc var visible: Bool { _visible }

    /// The overlay was shown or hidden: passed on to the pager (REF-GRID-015). Clearing the selected
    /// and dragged-over items and the pager layer's timers come with phases 2 to 4.
    @objc(setVisible:)
    func setVisible(_ visible: Bool) {
        guard _visible != visible else { return }
        _visible = visible
        pager.setVisible(visible)
    }

    @objc func layout() {
        let bounds = layer.bounds
        if bounds != .zero, bounds.width <= 1 || bounds.height <= 1 {
            Logger().error("Layer bounds is too small to layout correctly (\(bounds.minX), \(bounds.minY)) - (\(bounds.width), \(bounds.height)).")
            return
        }
        layer.layout()
    }

    // MARK: - ECPagerSource

    func numberOfPages(for pager: ECPager) -> UInt {
        UInt(item.items?.count ?? 0)
    }

    func pageItems(for pager: ECPager) -> NSArray? {
        item.items
    }

    /// Loads the page's items, then makes its page and grid layer.
    func makePage(for pager: ECPager, at index: UInt) -> ECPage? {
        guard let pageItems = item.items, index < pageItems.count,
              let pageItem = pageItems[Int(index)] as? ECSBPageItem else { return nil }
        _loadItemsForPageItem(pageItem)
        let page = ECSBPage(pager: self.pager, layer: nil, index: index, item: pageItem, scaleFactor: scaleFactor,
                            layoutRTL: layoutRTL)
        pageItem.page = page
        page.handler = handler
        let gridLayer = ECSBGridLayer(layerSource: page, rows: Int(numberOfRowsPerPage), columns: Int(numberOfColumnsPerPage),
                                      scaleFactor: scaleFactor, layoutRTL: layoutRTL)
        page.layer = gridLayer
        return page
    }

    func layoutPage(_ page: ECPage, for pager: ECPager) {
        guard page is ECSBPage else { return }
        (page.layer as? ECGridLayer)?.layout()
    }

    // MARK: - Loading the item tree

    /// The page's apps and folders, with each folder's pages and apps.
    @objc(_loadItemsForPageItem:)
    func _loadItemsForPageItem(_ pageItem: ECSBPageItem) {
        guard let client = pageItem.clientItem,
              let children = handler.value(forKey: "items", ofItem: client, withInfo: nil) as? NSArray else { return }
        let items = NSMutableArray(capacity: children.count)
        for child in children {
            let kind = handler.value(forKey: "kind", ofItem: child as AnyObject, withInfo: nil) as? String
            if kind == "group" {
                let groupItem = ECSBGroupItem()
                groupItem.clientItem = child as AnyObject
                groupItem.parent = pageItem
                _loadItemsForGroupItem(groupItem)
                items.add(groupItem)
            } else {
                let gridItem = ECSBItem()
                gridItem.clientItem = child as AnyObject
                gridItem.parent = pageItem
                items.add(gridItem)
            }
        }
        pageItem.items = items
    }

    @objc(_loadItemsForGroupItem:)
    func _loadItemsForGroupItem(_ groupItem: ECSBGroupItem) {
        guard let client = groupItem.clientItem,
              let pages = handler.value(forKey: "items", ofItem: client, withInfo: nil) as? NSArray else { return }
        let items = NSMutableArray(capacity: pages.count)
        for page in pages {
            let pageItem = ECSBPageItem()
            pageItem.clientItem = page as AnyObject
            pageItem.parent = groupItem
            _loadItemsForPageItem(pageItem)
            items.add(pageItem)
        }
        groupItem.items = items
    }
}

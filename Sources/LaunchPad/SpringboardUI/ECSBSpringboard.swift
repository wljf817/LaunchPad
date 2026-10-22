import os
import QuartzCore

/// The main grid: the item tree that mirrors the layout, and the pager that shows its pages
/// (REF-ARCH-005, REF-ARCH-006, research paper §6). It talks to the controller only through the
/// data source protocol (REF-ARCH-013).
@MainActor
@objc(ECSBSpringboard)
final class ECSBSpringboard: NSObject, ECPagerSource {
    /// The controller. It holds this object too; neither is released (REF-ARCH-006).
    @objc var handler: ECSBDataSource
    let item = ECSBSpringboardItem()
    var numberOfRowsPerPage: UInt
    var numberOfColumnsPerPage: UInt
    var _pager: ECSBPager!
    var scaleFactor: Float
    var layoutRTL: Bool

    @objc(initWithHandler:numberOfRowsPerPage:numberOfColumnsPerPage:scaleFactor:layoutRTL:)
    init(handler: ECSBDataSource, numberOfRowsPerPage: UInt, numberOfColumnsPerPage: UInt, scaleFactor: Float,
         layoutRTL: Bool) {
        self.scaleFactor = scaleFactor
        self.layoutRTL = layoutRTL
        self.handler = handler
        self.numberOfRowsPerPage = numberOfRowsPerPage
        self.numberOfColumnsPerPage = numberOfColumnsPerPage
        super.init()
        _pager = ECSBPager(pagerSource: self, scaleFactor: scaleFactor, layoutRTL: layoutRTL)
    }

    @objc var pager: ECSBPager {
        _pager
    }

    @objc var layer: ECSBLayer {
        pager.layer as! ECSBLayer
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

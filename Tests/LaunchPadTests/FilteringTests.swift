import Foundation
import LaunchPadPrivate
import QuartzCore
import Testing
@testable import LaunchPad

/// The main grid's filtering state and the centered single row of search pages (REF-SEARCH-010,
/// REF-GRID-008).
@MainActor
@Suite(.serialized)
struct FilteringTests {
    // MARK: - Centering a single row (REF-GRID-008)

    /// A grid layer of 5 × 7 cells over 1234 × 757, so 176 points a column, laid out with `count`
    /// items; returns the x of every item layer.
    func itemXs(count: UInt, centered: Bool, rtl: Bool = false) -> [CGFloat] {
        let source = FilteringLayerSource(count: count)
        let gridLayer = ECSBGridLayer(layerSource: source, rows: 5, columns: 7, scaleFactor: 1, layoutRTL: rtl)
        gridLayer.centerSingleRow = centered
        gridLayer.frame = CGRect(x: 0, y: 0, width: 1234, height: 757)
        gridLayer.layout()
        return (gridLayer.itemLayers as! [CALayer]).map(\.position.x)
    }

    @Test("单行居中：3 项时整行右移 352，从右到左时镜像")
    func centeredRow() {
        #expect(itemXs(count: 3, centered: true) == [440, 616, 792])
        #expect(itemXs(count: 3, centered: true, rtl: true) == [794, 618, 442])
    }

    @Test("单行居中：项数等于列数时与不居中相同")
    func fullRow() {
        #expect(itemXs(count: 7, centered: true) == [88, 264, 440, 616, 792, 968, 1144])
    }

    @Test("不居中时 3 项从左边排起")
    func notCentered() {
        #expect(itemXs(count: 3, centered: false) == [88, 264, 440])
    }

    // MARK: - Filtering state (REF-SEARCH-010)

    func centerSingleRows(_ grid: ECSBSpringboard) -> [Bool] {
        (grid.pager.pages as! [ECSBPage]).map { ($0.layer as! ECSBGridLayer).centerSingleRow }
    }

    @Test("在第二页第一次过滤时记下 1、不带动画地换到第 0 页；第二次过滤不再记")
    func enterFromSecondPage() {
        let scene = FilteringGrid()
        let (grid, source) = (scene.grid, scene.source)
        grid.currentPageIndex = 1
        CATransaction.flush()
        grid.layer.scrollLayer.removeAllAnimations()
        grid.filterUsingItems(source.search(3))
        CATransaction.flush()
        #expect(grid.filtering)
        #expect(grid._filteredPageIndex == 1)
        #expect(grid.currentPageIndex == 0)
        #expect(grid.layer.scrollLayer.animation(forKey: "bounds") == nil)
        grid.filterUsingItems(source.search(2))
        #expect(grid._filteredPageIndex == 1)
        #expect(grid.currentPageIndex == 0)
    }

    @Test("没有结果时「无结果」以隐式动画变为不透明；有结果时不带动画地变为透明")
    func noResults() throws {
        let scene = FilteringGrid()
        let (grid, source) = (scene.grid, scene.source)
        let noResultsLayer = try #require(grid.layer.noResultsLayer())
        CATransaction.begin()
        grid.filterUsingItems(source.search(0))
        CATransaction.commit()
        #expect(noResultsLayer.opacity == 1)
        #expect(noResultsLayer.animation(forKey: "opacity") != nil)
        noResultsLayer.removeAllAnimations()
        CATransaction.begin()
        grid.filterUsingItems(source.search(3))
        CATransaction.commit()
        #expect(noResultsLayer.opacity == 0)
        #expect(noResultsLayer.animation(forKey: "opacity") == nil)
    }

    @Test("过滤后选中当前页的第一项")
    func selectsFirstResult() {
        let scene = FilteringGrid()
        let (grid, source) = (scene.grid, scene.source)
        let results = source.search(3)
        grid.filterUsingItems(results)
        #expect(grid.selectedItem === results[0] as AnyObject)
    }

    @Test("过滤中建的网格 layer 单行居中，清空后建的不居中")
    func centerSingleRowWhileFiltering() {
        let scene = FilteringGrid()
        let (grid, source) = (scene.grid, scene.source)
        #expect(centerSingleRows(grid) == [false, false, false])
        grid.filterUsingItems(source.search(3))
        #expect(centerSingleRows(grid) == [true])
        source.searchPages = nil
        grid.clearFilteredItems()
        #expect(centerSingleRows(grid) == [false, false, false])
    }

    @Test("清空过滤：退出过滤，搜索框没有文字、「无结果」透明，都不带动画，回到第 1 页，没有选中项")
    func clear() throws {
        let scene = FilteringGrid()
        let (grid, source) = (scene.grid, scene.source)
        let field = try #require(grid.layer.searchTextInputLayer())
        let noResultsLayer = try #require(grid.layer.noResultsLayer())
        grid.currentPageIndex = 1
        field.stringValue = "Pro"
        grid.filterUsingItems(source.search(0))
        CATransaction.flush()
        noResultsLayer.removeAllAnimations()
        grid.layer.scrollLayer.removeAllAnimations()
        source.searchPages = nil
        CATransaction.begin()
        grid.clearFilteredItems()
        CATransaction.commit()
        #expect(!grid.filtering)
        #expect(field.stringValue == "")
        #expect(noResultsLayer.opacity == 0)
        #expect(noResultsLayer.animation(forKey: "opacity") == nil)
        #expect(grid.currentPageIndex == 1)
        #expect(grid.layer.scrollLayer.animation(forKey: "bounds") == nil)
        #expect(grid.selectedItem == nil)
    }
}

/// A main grid of three pages of four items each, laid out as at the first open, in a window, its
/// layer tree committed so implicit changes animate.
@MainActor
final class FilteringGrid {
    let source = FilteringSource(pages: [4, 4, 4])
    let grid: ECSBSpringboard
    let window: WALayerKitWindow

    init() {
        grid = ECSBSpringboard(handler: source, numberOfRowsPerPage: 5, numberOfColumnsPerPage: 7, scaleFactor: 1,
                               layoutRTL: false)
        let display = CGMainDisplayID()
        window = WALayerKitWindow(frame: CGDisplayBounds(display), connection: UInt32(bitPattern: CGSMainConnectionID()),
                                  display: display, tags: 0x400, level: 20)
        let saved = dockBar.display
        dockBar.display = DisplayDescriptor(notchBounds: .null)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grid.invalidate()
        window.layer.addSublayer(grid.layer)
        grid.layer.frame = CGRect(x: 0, y: 101, width: 1536, height: 859)
        (grid.leftMargin, grid.rightMargin, grid.topMargin, grid.bottomMargin) = (90, 90, 35, 37)
        grid.zoomFactor = 0.2
        grid.layout()
        CATransaction.commit()
        CATransaction.flush()
        dockBar.display = saved
    }
}

/// Makes a plain layer for every item.
@MainActor
final class FilteringLayerSource: NSObject, ECLayerSource {
    let count: UInt

    init(count: UInt) {
        self.count = count
    }

    func numberOfItems(for layer: CALayer) -> UInt {
        count
    }

    func setContent(inLayers layers: NSArray, withDataRange range: NSRange, for layer: CALayer, usingScaleFactor scaleFactor: Float) {}

    func makeLayer(for layer: CALayer, at index: UInt) -> CALayer? {
        CALayer()
    }
}

/// Pages of apps, standing in for the controller; while `searchPages` is set the root's items are those
/// pages, as the controller's are while it searches.
@MainActor
final class FilteringSource: NSObject, ECSBDataSource {
    final class Page: NSObject {
        let items: [NSObject]
        init(items: [NSObject]) {
            self.items = items
        }
    }

    let pages: [Page]
    var searchPages: [Page]?

    init(pages: [Int]) {
        self.pages = pages.map { count in Page(items: (0..<count).map { _ in NSObject() }) }
    }

    /// Makes `count` results, on a search page when there are any, and returns them.
    func search(_ count: Int) -> NSArray {
        let results = (0..<count).map { _ in NSObject() }
        searchPages = results.isEmpty ? [] : [Page(items: results)]
        return results as NSArray
    }

    func value(forKey key: String, ofItem item: AnyObject?, withInfo info: AnyObject?) -> AnyObject? {
        guard key == "items" else { return nil }
        if item == nil {
            return (searchPages ?? pages) as NSArray
        }
        return (item as? Page)?.items as NSArray?
    }
}

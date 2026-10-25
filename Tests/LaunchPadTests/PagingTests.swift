import CoreGraphics
import LaunchPadPrivate
import QuartzCore
import Testing
@testable import LaunchPad

/// The page indicator (REF-PAGING-003, REF-PAGING-004), checked against the values the original
/// showed in the reference VM.
@MainActor
@Suite(.serialized)
struct PagingTests {
    func components(_ color: CGColor?) -> [CGFloat] {
        color?.components ?? []
    }

    // MARK: - Dots (REF-PAGING-004)

    @Test("圆点：里面的 layer 不参与命中、颜色是「其他」；布局后居中 8×8、圆角 4")
    func indicatorLayout() throws {
        let dot = ECPagerIndicatorLayer()
        #expect(dot.sublayers?.count == 1)
        let inner = try #require(dot.sublayers?.first)
        #expect(inner.allowsHitTesting == false)
        #expect(components(inner.backgroundColor) == [1, 0.2])
        #expect(dot.state == 0)
        dot.frame = CGRect(x: 740, y: 0, width: 15, height: 15)
        dot.layout()
        #expect(inner.frame == CGRect(x: 3, y: 3, width: 8, height: 8))
        #expect(inner.cornerRadius == 4)
    }

    @Test("圆点的状态：1 是「当前」、0 是「其他」；值不变时不重设颜色")
    func indicatorState() throws {
        let dot = ECPagerIndicatorLayer()
        let inner = try #require(dot.sublayers?.first)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.state = 1
        #expect(components(inner.backgroundColor) == [1, 1])
        inner.backgroundColor = CGColor(gray: 0.5, alpha: 1)
        dot.state = 1
        #expect(components(inner.backgroundColor) == [0.5, 1])
        dot.state = 0
        #expect(components(inner.backgroundColor) == [1, 0.2])
        #expect(inner.contents == nil)
        #expect(inner.minificationFilter == .linear)
        CATransaction.commit()
    }

    /// A window whose layer tree runs implicit animations, as `WindowTests` makes one.
    func makeWindow() -> WALayerKitWindow {
        WindowTests.waitForMenuBar()
        let display = CGMainDisplayID()
        let window = WALayerKitWindow(frame: CGDisplayBounds(display), connection: UInt32(bitPattern: CGSMainConnectionID()),
                                      display: display, tags: 0x400, level: 20)
        CATransaction.flush()
        return window
    }

    @Test("圆点在显式事务里改状态时颜色有动画，关掉隐式动画时没有")
    func indicatorStateAnimation() throws {
        let window = makeWindow()
        let animated = ECPagerIndicatorLayer()
        let still = ECPagerIndicatorLayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.layer.addSublayer(animated)
        window.layer.addSublayer(still)
        CATransaction.commit()
        CATransaction.flush()

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.5)
        animated.state = 1
        CATransaction.commit()
        let inner = try #require(animated.sublayers?.first)
        let animation = try #require(inner.animation(forKey: "backgroundColor") as? CABasicAnimation)
        #expect(animation.duration == 0.5)
        #expect(components((animation.fromValue as! CGColor)) == [1, 0.2])

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        still.state = 1
        CATransaction.commit()
        #expect(still.sublayers?.first?.animation(forKey: "backgroundColor") == nil)

        animated.removeFromSuperlayer()
        still.removeFromSuperlayer()
    }

    // MARK: - The page indicator (REF-PAGING-003)

    /// A main grid of `pages` empty pages laid out with the original's default geometry at the first
    /// open (REF-GRID-004, REF-GRID-005).
    func makeGrid(pages: Int, rtl: Bool = false, visibility: Int = 2,
                  source: PageSource? = nil) -> (ECSBSpringboard, PageSource) {
        let source = source ?? PageSource(count: pages)
        let grid = ECSBSpringboard(handler: source, numberOfRowsPerPage: 5, numberOfColumnsPerPage: 7, scaleFactor: 1,
                                   layoutRTL: rtl)
        grid.pagerControlVisibility = visibility
        let saved = dockBar.display
        dockBar.display = DisplayDescriptor(notchBounds: .null)
        grid.invalidate()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grid.layer.frame = CGRect(x: 0, y: 101, width: 1536, height: 859)
        (grid.leftMargin, grid.rightMargin, grid.topMargin, grid.bottomMargin) = (90, 90, 35, 37)
        grid.zoomFactor = 0.2
        grid.layout()
        CATransaction.commit()
        dockBar.display = saved
        return (grid, source)
    }

    func dots(_ grid: ECSBSpringboard) -> [ECPagerIndicatorLayer] {
        grid.layer.controlLayer.indicatorLayers as! [ECPagerIndicatorLayer]
    }

    @Test("一页、两页、三页时圆点的个数、frame 和状态与原版相同")
    func indicatorFrames() {
        let (three, _) = makeGrid(pages: 3)
        #expect(three.layer.controlLayer.frame == CGRect(x: 0, y: 11, width: 1536, height: 15))
        #expect(three.layer.controlLayer.isHidden == false)
        #expect(dots(three).map(\.frame) == [740, 760, 780].map { CGRect(x: $0, y: 0, width: 15, height: 15) })
        #expect(dots(three).map(\.state) == [1, 0, 0])
        #expect(dots(three).map(\.index) == [0, 1, 2])
        #expect(dots(three).allSatisfy { $0.eventDelegate === three.layer.controlLayer })

        let (two, _) = makeGrid(pages: 2)
        #expect(dots(two).map(\.frame.minX) == [750, 770])

        let (one, _) = makeGrid(pages: 1)
        #expect(one.layer.controlLayer.isHidden == true)
        #expect(dots(one).map(\.frame) == [CGRect(x: 760, y: 0, width: 15, height: 15)])
    }

    @Test("从右到左时圆点从右往左排，第一页的圆点在最右")
    func indicatorRightToLeft() {
        let (grid, _) = makeGrid(pages: 3, rtl: true)
        #expect(dots(grid).map(\.frame.minX) == [780, 760, 740])
        #expect(dots(grid).map(\.state) == [1, 0, 0])
    }

    @Test("写作方向变了才重新排圆点")
    func indicatorLayoutRTL() {
        let (grid, _) = makeGrid(pages: 3)
        let control = grid.layer.controlLayer
        control.layoutRTL = true
        #expect(dots(grid).map(\.frame.minX) == [780, 760, 740])
        dots(grid)[0].frame.origin.x = 0
        control.layoutRTL = true
        #expect(dots(grid)[0].frame.minX == 0)
    }

    @Test("页数减少时从末尾删掉圆点")
    func indicatorShrinks() {
        let (grid, source) = makeGrid(pages: 3)
        let before = dots(grid)
        source.count = 2
        grid.invalidate()
        #expect(dots(grid).count == 2)
        #expect(dots(grid)[0] === before[0] && dots(grid)[1] === before[1])
        #expect(before[2].superlayer == nil)
    }

    @Test("显示方式 0 至 3：一页和多页时的隐藏和页的底边")
    func indicatorVisibility() {
        // REF-PAGING-003 and REF-GRID-007: hidden, and the scroll layer's y (37, or 22 with the room given).
        let expected: [(Int, Int, Bool, CGFloat)] = [
            (0, 1, false, 37), (0, 3, false, 37),
            (1, 1, true, 22), (1, 3, true, 22),
            (2, 1, true, 37), (2, 3, false, 37),
            (3, 1, true, 22), (3, 3, false, 37),
        ]
        for (visibility, pages, hidden, bottom) in expected {
            let (grid, _) = makeGrid(pages: pages, visibility: visibility)
            #expect(grid.layer.controlLayer.isHidden == hidden, "\(visibility), \(pages)")
            #expect(grid.layer.scrollLayer.frame.minY == bottom, "\(visibility), \(pages)")
        }
    }

    @Test("指示器的竖直位置用设好的下边距，低于 0 时为 0")
    func indicatorUsesBottomMargin() {
        let (grid, _) = makeGrid(pages: 3)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grid.bottomMargin = 58
        grid.layout()
        #expect(grid.layer.controlLayer.frame.minY == 21)
        grid.bottomMargin = 10
        grid.layout()
        #expect(grid.layer.controlLayer.frame.minY == 0)
        CATransaction.commit()
    }

    @Test("主网格 layer 的子 layer 依次是滚动 layer 和页码指示器；显示方式经 pager 设到 pager layer")
    func indicatorInTree() {
        let (grid, _) = makeGrid(pages: 3)
        #expect(grid.layer.sublayers?.count == 2)
        #expect(grid.layer.sublayers?[0] === grid.layer.scrollLayer)
        #expect(grid.layer.sublayers?[1] === grid.layer.controlLayer)
        grid.pagerControlVisibility = 3
        #expect(grid.pager.pagerControlVisibility == 3)
        #expect(grid.layer.pagerControlVisibility == 3)
    }

    // MARK: - Current page and scrolling (REF-PAGING-001, REF-PAGING-002)

    @Test("换到另一页：当前页、滚动终点、圆点的状态和「最近看过」")
    func switchPage() {
        let (grid, _) = makeGrid(pages: 3)
        #expect(grid.currentPageIndex == 0)
        grid.currentPageIndex = 1
        #expect(grid.currentPageIndex == 1)
        #expect(grid.pager.currentPageIndex == 1 && grid.layer.currentPageIndex == 1)
        #expect(grid.layer.scrollLayer.bounds.minX == 1536)
        #expect(dots(grid).map(\.state) == [0, 1, 0])
        #expect((grid.pager.pages as! [ECSBPage]).map(\.recentlyViewed) == [false, true, false])
        #expect(grid.currentPage === grid.pager.pages[1] as AnyObject)
        #expect(grid.pager.currentPage === grid.pager.pages[1] as AnyObject)
        grid.currentPageIndex = 2
        #expect(grid.layer.scrollLayer.bounds.minX == 3072)
        #expect(dots(grid).map(\.state) == [0, 0, 1])
    }

    @Test("从右到左时滚动终点按镜像的页序号")
    func switchPageRightToLeft() {
        let (grid, _) = makeGrid(pages: 3, rtl: true)
        #expect(grid.layer.scrollLayer.bounds.minX == 3072)
        grid.currentPageIndex = 2
        #expect(grid.layer.scrollLayer.bounds.minX == 0)
        grid.currentPageIndex = 1
        #expect(grid.layer.scrollLayer.bounds.minX == 1536)
        #expect(dots(grid).map(\.state) == [0, 1, 0])
    }

    @Test("设为当前页时只滚回原位")
    func samePage() {
        let (grid, _) = makeGrid(pages: 3)
        grid.currentPageIndex = 1
        grid.layer.scrollLayer.scroll(to: CGPoint(x: 100, y: 0))
        grid.currentPageIndex = 1
        #expect(grid.currentPageIndex == 1)
        #expect(grid.layer.scrollLayer.bounds.minX == 1536)
    }

    @Test("超出页数时不变；没有页时设 0 记为 0")
    func pastEnd() {
        let (two, _) = makeGrid(pages: 2)
        two.currentPageIndex = 2
        #expect(two.currentPageIndex == 0)
        #expect(two.layer.scrollLayer.bounds.minX == 0)
        let (none, _) = makeGrid(pages: 0)
        none.layer._currentPageIndex = 3
        none.currentPageIndex = 1
        #expect(none.currentPageIndex == 3)
        none.currentPageIndex = 0
        #expect(none.currentPageIndex == 0)
        #expect(none.currentPage == nil)
    }

    @Test("pager 禁止滚动时设当前页和滚动值都不动")
    func disableScrolling() {
        let (grid, _) = makeGrid(pages: 3)
        #expect(grid.pager.disableScrolling == false)
        grid.pager.disableScrolling = true
        grid.currentPageIndex = 1
        grid.layer.scrollValue = 500
        #expect(grid.currentPageIndex == 0)
        #expect(grid.layer.scrollValue == 0)
    }

    @Test("滚动值超出第一页左边或最后一页右边的部分只走四分之一")
    func scrollValueBeyondEnds() {
        let (grid, _) = makeGrid(pages: 3)
        grid.layer.scrollValue = 1000
        #expect(grid.layer.scrollValue == 1000)
        grid.layer.scrollValue = -100
        #expect(grid.layer.scrollValue == -25)
        grid.layer.scrollValue = 3172
        #expect(grid.layer.scrollValue == 3097)
        #expect(grid.currentPageIndex == 0)
    }

    @Test("重建后滚动值和当前页都是 0，不发换页回调")
    func invalidate() {
        let recorder = PageChangeRecorder(count: 3)
        let (grid, _) = makeGrid(pages: 3, source: recorder)
        grid.currentPageIndex = 2
        grid.layer.scrollValue = 700
        recorder.log.removeAll()
        grid.invalidate()
        #expect(grid.currentPageIndex == 0)
        #expect(grid.layer.scrollValue == 0)
        #expect(recorder.log.isEmpty)
    }

    @Test("翻页时长：没设偏好时 0.5，第一次读到的值之后不再读，读到负数时下次重读，慢放时 5")
    func scrollDuration() {
        let key = "springboard-page-duration"
        let defaults = UserDefaults.standard
        defer {
            defaults.removeObject(forKey: key)
            springboardPageDuration = -1
        }
        defaults.removeObject(forKey: key)
        springboardPageDuration = -1
        #expect(ECPagerLayer.scrollDuration(slow: false) == 0.5)
        defaults.set(1.5, forKey: key)
        #expect(ECPagerLayer.scrollDuration(slow: false) == 0.5)

        springboardPageDuration = -1
        #expect(ECPagerLayer.scrollDuration(slow: false) == 1.5)
        defaults.set(0.3, forKey: key)
        #expect(ECPagerLayer.scrollDuration(slow: false) == 1.5)

        springboardPageDuration = -1
        defaults.set(-1, forKey: key)
        #expect(ECPagerLayer.scrollDuration(slow: false) == -1)
        defaults.set(0.3, forKey: key)
        #expect(ECPagerLayer.scrollDuration(slow: false) == CFTimeInterval(Float(0.3)))

        springboardPageDuration = -1
        defaults.set("1.5", forKey: key)
        #expect(ECPagerLayer.scrollDuration(slow: false) == 0.5)

        springboardPageDuration = -1
        defaults.set(1.5, forKey: key)
        #expect(ECPagerLayer.scrollDuration(slow: true) == 5)
        #expect(springboardPageDuration == -1)
    }

    func controlPoints(_ function: CAMediaTimingFunction?) -> [[Float]] {
        guard let function else { return [] }
        return (0..<4).map { index in
            var point: [Float] = [0, 0]
            function.getControlPoint(at: index, values: &point)
            return point
        }
    }

    @Test("换页时滚动 layer 的 bounds 和变了状态的圆点颜色在同一个动画里，时长 0.5、曲线按 REF-PAGING-002；滚回原位没有动画")
    func scrollAnimation() throws {
        let window = makeWindow()
        let (grid, _) = makeGrid(pages: 3)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.layer.addSublayer(grid.layer)
        CATransaction.commit()
        CATransaction.flush()
        UserDefaults.standard.removeObject(forKey: "springboard-page-duration")
        springboardPageDuration = -1
        defer {
            grid.layer.removeFromSuperlayer()
            springboardPageDuration = -1
        }

        let scrollLayer = grid.layer.scrollLayer
        let before = scrollLayer.bounds
        grid.currentPageIndex = 1
        let animation = try #require(scrollLayer.animation(forKey: "bounds") as? CABasicAnimation)
        #expect(animation.duration == 0.5)
        let points = controlPoints(animation.timingFunction)
        #expect(points[0] == [0, 0] && points[3] == [1, 1])
        // REF-PAGING-002: single precision 0x3EB78184 and 0x3F803E42.
        #expect(points[1] == [0, 0])
        #expect(points[2].map(\.bitPattern) == [0x3EB7_8184, 0x3F80_3E42])
        #expect((animation.fromValue as? NSValue)?.rectValue == before)
        #expect(scrollLayer.bounds == CGRect(x: 1536, y: 0, width: before.width, height: before.height))

        let inner = dots(grid).map { $0.sublayers![0] }
        for changed in [inner[0], inner[1]] {
            let color = try #require(changed.animation(forKey: "backgroundColor") as? CABasicAnimation)
            #expect(color.duration == 0.5)
            #expect(controlPoints(color.timingFunction) == points)
        }
        #expect(inner[2].animation(forKey: "backgroundColor") == nil)

        scrollLayer.removeAllAnimations()
        inner.forEach { $0.removeAllAnimations() }
        grid.currentPageIndex = 1
        #expect(scrollLayer.animation(forKey: "bounds") == nil)
        #expect(inner.allSatisfy { $0.animation(forKey: "backgroundColor") == nil })
    }
}

/// A data source that records the page changes it is told about and the cancels, with where the
/// scroll layer is at that moment.
@MainActor
final class PageChangeRecorder: PageSource, ECSBDelegate, ECSBActionHandling {
    var log: [String] = []
    weak var grid: ECSBSpringboard?

    var scroll: CGFloat {
        grid?.layer.scrollLayer.bounds.minX ?? -1
    }

    func describe(_ page: AnyObject?) -> String {
        "page \(pages.firstIndex { $0 === page }.map(String.init) ?? "?")"
    }

    func willChangeToPage(_ page: AnyObject?) {
        log.append("handler will \(describe(page)), at \(Int(scroll))")
    }

    func didChangeToPage(_ page: AnyObject?) {
        log.append("handler did \(describe(page)), at \(Int(scroll))")
    }

    func performAction(forItem item: AnyObject?, with event: ECEvent?, sender: AnyObject?) {}

    func cancelAction(with event: ECEvent?, sender: AnyObject?) {
        log.append("cancel")
    }
}

/// `count` empty pages, as the layout root's children.
@MainActor
class PageSource: NSObject, ECSBDataSource {
    var count: Int
    var pages: [NSObject] = []

    init(count: Int) {
        self.count = count
    }

    func value(forKey key: String, ofItem item: AnyObject?, withInfo info: AnyObject?) -> AnyObject? {
        switch key {
        case "items":
            if item == nil {
                while pages.count < count {
                    pages.append(NSObject())
                }
                return Array(pages.prefix(count)) as NSArray
            }
            return NSArray()
        case "kind":
            return "page" as NSString
        default:
            return nil
        }
    }
}

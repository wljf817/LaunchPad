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
    func makeGrid(pages: Int, rtl: Bool = false, visibility: Int = 2) -> (ECSBSpringboard, PageSource) {
        let source = PageSource(count: pages)
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
}

/// `count` empty pages, as the layout root's children.
@MainActor
final class PageSource: NSObject, ECSBDataSource {
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

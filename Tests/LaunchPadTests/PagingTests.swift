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

    // MARK: - Page change callbacks (REF-PAGING-001)

    @Test("换页的先后：清选中项、pager source 的 will、handler 的 will、滚动、pager source 的 did、handler 的 did；参数是新页的模型页")
    func pageChangeCallbacks() {
        let recorder = PageChangeRecorder(count: 3)
        let (grid, _) = makeGrid(pages: 3, source: recorder)
        let pagerSource = RecordingPagerSource(grid: grid, recorder: recorder)
        grid.pager.pagerSource = pagerSource
        recorder.grid = grid
        grid.pager.selectedItem = ECSBItem()
        grid.currentPageIndex = 1
        #expect(recorder.log == ["source will 1, selected nil, at 0", "handler will page 1, at 0",
                                 "source did 1, at 1536", "handler did page 1, at 1536"])
        recorder.log.removeAll()
        grid.currentPageIndex = 1
        grid.currentPageIndex = 3
        #expect(recorder.log.isEmpty)
        withExtendedLifetime(pagerSource) {}
    }

    @Test("pager source 或 handler 不响应时不发")
    func pageChangeCallbacksNotResponding() {
        let recorder = DidOnlyRecorder(count: 3)
        let (grid, _) = makeGrid(pages: 3, source: recorder)
        grid.currentPageIndex = 2
        #expect(grid.currentPageIndex == 2)
        #expect(recorder.pagesChangedTo.count == 1)
        #expect((recorder.pagesChangedTo.first ?? nil) === recorder.pages[2])
    }

    @Test("-setVisible: 以后只有当前页是「最近看过」")
    func recentlyViewedOnVisible() {
        let (grid, _) = makeGrid(pages: 3)
        grid.currentPageIndex = 1
        let pages = grid.pager.pages as! [ECSBPage]
        pages[0].recentlyViewed = true
        pages[2].recentlyViewed = true
        grid.setVisible(true)
        #expect(pages.map(\.recentlyViewed) == [false, true, false])
        pages.forEach { $0.recentlyViewed = true }
        grid.setVisible(false)
        #expect(pages.map(\.recentlyViewed) == [false, true, false])
    }

    @Test("打开再关闭不改当前页，打开后仍显示那一页")
    func openAndCloseKeepPage() {
        let controller = QuietSpringboard()
        let root = LPRoot()
        for _ in 0..<3 {
            root.children.add(LPPage(items: nil))
        }
        controller.rootPage = root
        controller.springboard.invalidate()
        controller.springboard.currentPageIndex = 1
        controller.setVisible(true, reason: "test")
        defer {
            controller._purgeItemsTimer?.cancel()
            controller._purgeItemsTimer = nil
        }
        #expect(controller.animations == [true])
        let grid: ECSBSpringboard = controller.springboard
        #expect(grid.currentPageIndex == 1)
        #expect(grid.layer.scrollLayer.bounds.minX == grid.layer.bounds.width)
        #expect(dots(grid).map(\.state) == [0, 1, 0])
        controller.setVisible(false, reason: "test")
        #expect(controller.animations == [true, false])
        #expect(grid.currentPageIndex == 1)
    }

    // MARK: - Clicking a dot (REF-PAGING-004)

    /// The main grid of three pages in a window, under a dispatcher's handler layer, and a function
    /// that sends a mouse event at a point of that layer (REF-OVERLAY-009).
    func makeClickableGrid() -> (ECSBSpringboard, PageChangeRecorder, (CGEventType, CGPoint) -> Void) {
        let window = makeWindow()
        let recorder = PageChangeRecorder(count: 3)
        let (grid, _) = makeGrid(pages: 3, source: recorder)
        recorder.grid = grid
        let top = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        top.frame = window.layer.bounds
        top.addSublayer(grid.layer)
        window.layer.addSublayer(top)
        CATransaction.commit()
        CATransaction.flush()
        let handler = RecordingHandler(layer: top)
        let controller = ECModalEventController()
        controller.addHandler(handler, externalEventSource: true, usingMouseHysteresis: true)
        let send = { (type: CGEventType, point: CGPoint) in
            let frame = window.frame()
            let global = CGPoint(x: frame.minX + point.x, y: frame.minY + frame.height - 1 - point.y)
            var windows = [window]
            var layers = [top]
            controller.handleEvent(mouseEvent(type, at: global), windows: &windows, topLayers: &layers, windowCount: 1)
            withExtendedLifetime(handler) {}
        }
        return (grid, recorder, send)
    }

    /// The center of dot `index` in the handler layer: the grid at y 101, the page indicator 11 above
    /// it, the dots 15 high (REF-PAGING-003).
    func dotCenter(_ grid: ECSBSpringboard, _ index: Int) -> CGPoint {
        CGPoint(x: dots(grid)[index].frame.midX, y: 101 + 11 + 7.5)
    }

    @Test("点第二个圆点换到第二页，覆盖层不关闭")
    func clickDot() {
        let (grid, recorder, send) = makeClickableGrid()
        defer { grid.layer.superlayer?.removeFromSuperlayer() }
        send(.leftMouseDown, dotCenter(grid, 1))
        #expect(grid.currentPageIndex == 0)
        send(.leftMouseUp, dotCenter(grid, 1))
        #expect(grid.currentPageIndex == 1)
        #expect(recorder.log == ["handler will page 1, at 0", "handler did page 1, at 1536"])
    }

    @Test("点当前页的圆点不发换页回调，覆盖层不关闭")
    func clickCurrentDot() {
        let (grid, recorder, send) = makeClickableGrid()
        defer { grid.layer.superlayer?.removeFromSuperlayer() }
        send(.leftMouseDown, dotCenter(grid, 0))
        send(.leftMouseUp, dotCenter(grid, 0))
        #expect(grid.currentPageIndex == 0)
        #expect(recorder.log.isEmpty)
    }

    @Test("点两个圆点之间与点空白处一样关闭")
    func clickBetweenDots() {
        let (grid, recorder, send) = makeClickableGrid()
        defer { grid.layer.superlayer?.removeFromSuperlayer() }
        let between = CGPoint(x: dots(grid)[0].frame.maxX + 2.5, y: 101 + 11 + 7.5)
        send(.leftMouseDown, between)
        send(.leftMouseUp, between)
        #expect(grid.currentPageIndex == 0)
        #expect(recorder.log == ["cancel"])
    }

    @Test("在第三个圆点上按下、拖到别处松开，换到第三页")
    func dragOffDot() {
        let (grid, recorder, send) = makeClickableGrid()
        defer { grid.layer.superlayer?.removeFromSuperlayer() }
        send(.leftMouseDown, dotCenter(grid, 2))
        send(.leftMouseDragged, CGPoint(x: 400, y: 500))
        send(.leftMouseUp, CGPoint(x: 400, y: 500))
        #expect(grid.currentPageIndex == 2)
        #expect(recorder.log == ["handler will page 2, at 0", "handler did page 2, at 3072"])
    }

    // MARK: - Drag scrolling (REF-PAGING-005)

    /// A mouse event at (x, y) whose CGEvent timestamp is `time` nanoseconds (REF-PAGING-005).
    func event(_ type: CGEventType, _ x: CGFloat, _ y: CGFloat, at time: UInt64) -> ECEvent {
        let cgEvent = mouseEvent(type, at: CGPoint(x: x, y: y))
        cgEvent.timestamp = time
        return ECEvent(event: cgEvent, hitLayer: nil, hitWindow: nil, session: nil)
    }

    /// Sends the main grid's pager layer a press at the first point, a drag to each further point and a
    /// release at the last one `milliseconds` after the press; the drags are spread evenly in between.
    /// The transaction is flushed after each event, as the dispatcher does (REF-OVERLAY-009). Returns the
    /// scroll value after each drag.
    @discardableResult
    func drag(_ grid: ECSBSpringboard, _ points: [(CGFloat, CGFloat)], milliseconds: UInt64) -> [CGFloat] {
        let start: UInt64 = 1_000_000_000
        let step = milliseconds * 1_000_000 / UInt64(points.count)
        _ = grid.layer.leftMouseDown(event(.leftMouseDown, points[0].0, points[0].1, at: start))
        CATransaction.flush()
        var values: [CGFloat] = []
        for (index, point) in points.enumerated().dropFirst() {
            _ = grid.layer.leftMouseDragged(event(.leftMouseDragged, point.0, point.1, at: start + UInt64(index) * step))
            CATransaction.flush()
            values.append(grid.layer.scrollValue)
        }
        let last = points[points.count - 1]
        _ = grid.layer.leftMouseUp(event(.leftMouseUp, last.0, last.1, at: start + milliseconds * 1_000_000))
        return values
    }

    @Test("横向离按下点不到开始的距离时页不动，纵向移动不算")
    func dragBelowStartDistance() {
        let (grid, _) = makeGrid(pages: 3)
        _ = grid.layer.leftMouseDown(event(.leftMouseDown, 1000, 60, at: 0))
        _ = grid.layer.leftMouseDragged(event(.leftMouseDragged, 1002, 200, at: 1))
        #expect(grid.layer.scrollValue == 0)
        #expect(!grid.layer.isDragScrolling)
        _ = grid.layer.leftMouseDragged(event(.leftMouseDragged, 997, 60, at: 2))
        #expect(grid.layer.isDragScrolling)
        #expect(grid.layer.scrollValue == 3)
    }

    @Test("开始以后滚动值等于按下时的滚动值加上指针向左移的距离，从第二页开始也对")
    func dragFollowsPointer() {
        let (grid, _) = makeGrid(pages: 3)
        grid.currentPageIndex = 1
        _ = grid.layer.leftMouseDown(event(.leftMouseDown, 1000, 60, at: 0))
        #expect(grid.layer.startScrollValue == 1536)
        _ = grid.layer.leftMouseDragged(event(.leftMouseDragged, 900, 80, at: 1))
        #expect(grid.layer.scrollValue == 1636)
        _ = grid.layer.leftMouseDragged(event(.leftMouseDragged, 1100, 40, at: 2))
        #expect(grid.layer.scrollValue == 1436)
        #expect(grid.layer.lastLocation == CGPoint(x: 1000, y: 60))
        #expect(grid.layer.lastTime == 0)
    }

    @Test("拖动中滚动 layer 上没有动画；隐式动画调用前开着就仍开着，关着就仍关着")
    func dragWithoutAnimation() {
        let window = makeWindow()
        let (grid, _) = makeGrid(pages: 3)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.layer.addSublayer(grid.layer)
        CATransaction.commit()
        CATransaction.flush()
        defer { grid.layer.removeFromSuperlayer() }
        let scrollLayer = grid.layer.scrollLayer
        _ = grid.layer.leftMouseDown(event(.leftMouseDown, 1000, 60, at: 0))
        _ = grid.layer.leftMouseDragged(event(.leftMouseDragged, 900, 60, at: 1))
        #expect(scrollLayer.animation(forKey: "bounds") == nil)
        #expect(!CATransaction.disableActions())
        CATransaction.setDisableActions(true)
        _ = grid.layer.leftMouseDragged(event(.leftMouseDragged, 800, 60, at: 2))
        #expect(CATransaction.disableActions())
        CATransaction.setDisableActions(false)
        #expect(scrollLayer.animation(forKey: "bounds") == nil)
        #expect(grid.layer.scrollValue == 200)
    }

    @Test("拉过第一页左边时按 REF-PAGING-002 只走四分之一")
    func dragPastFirstPage() {
        let (grid, _) = makeGrid(pages: 3)
        _ = grid.layer.leftMouseDown(event(.leftMouseDown, 400, 60, at: 0))
        _ = grid.layer.leftMouseDragged(event(.leftMouseDragged, 800, 60, at: 1))
        #expect(grid.layer.scrollValue == -100)
    }

    @Test("拖动中当前页和圆点的状态不变，handler 收不到换页回调")
    func dragKeepsPage() {
        let recorder = PageChangeRecorder(count: 3)
        let (grid, _) = makeGrid(pages: 3, source: recorder)
        recorder.grid = grid
        _ = grid.layer.leftMouseDown(event(.leftMouseDown, 1300, 60, at: 0))
        _ = grid.layer.leftMouseDragged(event(.leftMouseDragged, 300, 60, at: 1))
        #expect(grid.layer.scrollValue == 1000)
        #expect(grid.currentPageIndex == 0)
        #expect(dots(grid).map(\.state) == [1, 0, 0])
        #expect(recorder.log.isEmpty)
    }

    @Test("从右到左时拖动的算法相同")
    func dragRightToLeft() {
        let (grid, _) = makeGrid(pages: 3, rtl: true)
        _ = grid.layer.leftMouseDown(event(.leftMouseDown, 400, 60, at: 0))
        _ = grid.layer.leftMouseDragged(event(.leftMouseDragged, 1000, 60, at: 1))
        #expect(grid.layer.scrollValue == 2472)
        #expect(grid.currentPageIndex == 0)
    }

    @Test("快拖过半页换到下一页，handler 先后收到 will 和 did；松开后不再在拖动翻页")
    func flickToNextPage() {
        let recorder = PageChangeRecorder(count: 3)
        let (grid, _) = makeGrid(pages: 3, source: recorder)
        recorder.grid = grid
        let values = drag(grid, [(1200, 60), (800, 60), (400, 60)], milliseconds: 100)
        #expect(values == [400, 800])
        #expect(grid.currentPageIndex == 1)
        #expect(grid.layer.scrollValue == 1536)
        #expect(recorder.log == ["handler will page 1, at 800", "handler did page 1, at 1536"])
        #expect(!grid.layer.isDragScrolling)
    }

    @Test("慢拖过半页滚回当前页，没有回调，动画的时长和曲线按 REF-PAGING-002；速度恰为阈值时也滚回")
    func slowDragScrollsBack() throws {
        let window = makeWindow()
        let recorder = PageChangeRecorder(count: 3)
        let (grid, _) = makeGrid(pages: 3, source: recorder)
        recorder.grid = grid
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
        // 800 points in 10 s: 0.8 (REF-PAGING-005).
        drag(grid, [(1200, 60), (400, 60)], milliseconds: 10_000)
        #expect(grid.currentPageIndex == 0)
        #expect(scrollLayer.bounds.minX == 0)
        #expect(recorder.log.isEmpty)
        let animation = try #require(scrollLayer.animation(forKey: "bounds") as? CABasicAnimation)
        #expect(animation.duration == 0.5)
        #expect(controlPoints(animation.timingFunction)[2].map(\.bitPattern) == [0x3EB7_8184, 0x3F80_3E42])
        #expect((animation.fromValue as? NSValue)?.rectValue.minX == 800)
        #expect(!grid.layer.isDragScrolling)
        scrollLayer.removeAllAnimations()
        // 200 points in 1 s: exactly 2.0.
        drag(grid, [(1200, 60), (1000, 60)], milliseconds: 1000)
        #expect(grid.currentPageIndex == 0)
        #expect(recorder.log.isEmpty)
    }

    @Test("在最后一页向左快拖滚回最后一页，没有回调")
    func flickOnLastPage() {
        let recorder = PageChangeRecorder(count: 3)
        let (grid, _) = makeGrid(pages: 3, source: recorder)
        recorder.grid = grid
        grid.currentPageIndex = 2
        recorder.log.removeAll()
        let values = drag(grid, [(1000, 60), (400, 60)], milliseconds: 100)
        #expect(values == [3222])
        #expect(grid.currentPageIndex == 2)
        #expect(grid.layer.scrollValue == 3072)
        #expect(recorder.log.isEmpty)
    }

    @Test("在第一页向右拉后松开，回到第一页")
    func pullFirstPage() {
        let recorder = PageChangeRecorder(count: 3)
        let (grid, _) = makeGrid(pages: 3, source: recorder)
        recorder.grid = grid
        let values = drag(grid, [(400, 60), (800, 60)], milliseconds: 100)
        #expect(values == [-100])
        #expect(grid.currentPageIndex == 0)
        #expect(grid.layer.scrollValue == 0)
        #expect(recorder.log.isEmpty)
    }

    @Test("从右到左在第一页向右快拖，到第二页")
    func flickRightToLeft() {
        let (grid, _) = makeGrid(pages: 3, rtl: true)
        drag(grid, [(400, 60), (1000, 60)], milliseconds: 100)
        #expect(grid.currentPageIndex == 1)
        #expect(grid.layer.scrollValue == 1536)
    }

    @Test("从左到右在第一页回到按下点、快速松开时到最后一页")
    func backToPressGoesToLastPage() {
        let recorder = PageChangeRecorder(count: 3)
        let (grid, _) = makeGrid(pages: 3, source: recorder)
        recorder.grid = grid
        let values = drag(grid, [(1000, 60), (990, 60), (1000, 200), (1000, 360)], milliseconds: 150)
        #expect(values == [10, 0, 0])
        #expect(grid.currentPageIndex == 2)
        #expect(recorder.log == ["handler will page 2, at 0", "handler did page 2, at 3072"])
    }

    @Test("从右到左在最后一页的对应情形什么也不发")
    func backToPressRightToLeft() {
        let recorder = PageChangeRecorder(count: 3)
        let (grid, _) = makeGrid(pages: 3, rtl: true, source: recorder)
        recorder.grid = grid
        grid.currentPageIndex = 2
        recorder.log.removeAll()
        drag(grid, [(1000, 60), (990, 60), (1000, 200), (1000, 360)], milliseconds: 150)
        #expect(grid.currentPageIndex == 2)
        #expect(grid.layer.scrollValue == 0)
        #expect(recorder.log.isEmpty)
    }

    @Test("没有在拖动翻页时松开，页不动；纵向拖过时也不取消")
    func releaseWithoutDragScrolling() {
        let recorder = PageChangeRecorder(count: 3)
        let (grid, _) = makeGrid(pages: 3, source: recorder)
        recorder.grid = grid
        drag(grid, [(1000, 60), (1002, 70)], milliseconds: 100)
        #expect(grid.currentPageIndex == 0)
        #expect(grid.layer.scrollValue == 0)
        #expect(recorder.log.isEmpty)
        #expect(!grid.layer.isDragScrolling)
    }

    @Test("在空白处按下、拖动翻页后松开，覆盖层不关闭")
    func dragDoesNotClose() {
        let (grid, recorder, send) = makeClickableGrid()
        defer { grid.layer.superlayer?.removeFromSuperlayer() }
        send(.leftMouseDown, CGPoint(x: 1000, y: 800))
        send(.leftMouseDragged, CGPoint(x: 600, y: 800))
        send(.leftMouseDragged, CGPoint(x: 200, y: 800))
        #expect(grid.layer.scrollValue == 800)
        send(.leftMouseUp, CGPoint(x: 200, y: 800))
        #expect(grid.currentPageIndex == 1)
        #expect(!recorder.log.contains("cancel"))
    }

    @Test("在一个应用的名称上按下后快拖，换到下一页，应用没有启动")
    func dragFromName() {
        let scene = SceneGrid(emptyPages: 1)
        let actions = RecordingGridActions()
        scene.grid.pager.gridActionHandler = actions
        let handler = RecordingHandler(layer: scene.top)
        let controller = ECModalEventController.sharedController()
        controller.addHandler(handler, externalEventSource: true, usingMouseHysteresis: true)
        defer { controller.removeHandler(handler) }
        let name = scene.name(3)
        let end = CGPoint(x: name.x - 600, y: name.y)
        scene.send(.leftMouseDown, name)
        scene.send(.leftMouseDragged, end)
        #expect(scene.grid.layer.scrollValue == 600)
        scene.send(.leftMouseUp, end)
        #expect(scene.grid.currentPageIndex == 1)
        #expect(actions.performed.isEmpty)
        #expect(actions.cancelled == 0)
    }

    // MARK: - Scroll wheel and gestures (REF-PAGING-006)

    /// A main grid of three pages that records the page changes, on `page`.
    func makeRecordedGrid(page: UInt = 0, rtl: Bool = false) -> (ECSBSpringboard, PageChangeRecorder) {
        let recorder = PageChangeRecorder(count: 3)
        let (grid, _) = makeGrid(pages: 3, rtl: rtl, source: recorder)
        recorder.grid = grid
        if page != 0 {
            grid.currentPageIndex = page
            grid.layer.scrollLayer.removeAllAnimations()
            recorder.log.removeAll()
        }
        return (grid, recorder)
    }

    /// Sends the main grid's pager layer a scroll wheel event with the fixed-point deltas given and
    /// flushes the transaction, as the dispatcher does (REF-OVERLAY-009). With the reversed scrolling
    /// of the default preference, a negative delta moves toward the next page (REF-PAGING-006).
    @discardableResult
    func wheel(_ grid: ECSBSpringboard, dx: Double = 0, dy: Double = 0, momentum: Int64 = 0) -> Bool {
        let handled = grid.layer.scrollWheel(ECEvent(event: scrollEvent(dx: dx, dy: dy, momentum: momentum, at: CGPoint(x: 1000, y: 60)),
                                                     hitLayer: nil, hitWindow: nil, session: nil))
        CATransaction.flush()
        return handled
    }

    /// Lets the scroll wheel's timer fire on the main queue (REF-PAGING-006).
    func waitForWheelTimer() async {
        try? await Task.sleep(for: .milliseconds(200))
    }

    @Test("反转偏好的读法：没设、不是数时为真，设为假时为假；默认的进程里为真")
    func reversePreference() {
        let key = "test-springboard-reverse-scroll-gesture"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        #expect(boolPreference(key, default: true))
        UserDefaults.standard.set("NO", forKey: key)
        #expect(boolPreference(key, default: true))
        UserDefaults.standard.set(false, forKey: key)
        #expect(!boolPreference(key, default: true))
        UserDefaults.standard.set(1, forKey: key)
        #expect(boolPreference(key, default: false))
        #expect(springboardReverseScrollGesture)
    }

    @Test("滚一格：页按系数移一点、没有动画，当前页和圆点不变；到时滑到第二页，先后收到 will 和 did")
    func wheelOneLine() async {
        let window = makeWindow()
        let (grid, recorder) = makeRecordedGrid()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.layer.addSublayer(grid.layer)
        CATransaction.commit()
        defer { grid.layer.removeFromSuperlayer() }
        #expect(wheel(grid, dy: -1))
        #expect(grid.layer.scrollValue == 2)
        #expect(grid.layer.scrollLayer.animationKeys() == nil)
        #expect(!CATransaction.disableActions())
        #expect(grid.currentPageIndex == 0)
        #expect(dots(grid).map(\.state) == [1, 0, 0])
        #expect(recorder.log.isEmpty)
        #expect(grid.layer.scrollWheelTimer != nil)
        await waitForWheelTimer()
        #expect(grid.currentPageIndex == 1)
        #expect(recorder.log == ["handler will page 1, at 2", "handler did page 1, at 1536"])
        #expect(grid.layer.scrollWheelTimer == nil)
    }

    @Test("调用前关着隐式动画时，滚动以后仍关着")
    func wheelKeepsDisabledActions() async {
        let (grid, _) = makeRecordedGrid()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        _ = grid.layer.scrollWheel(ECEvent(event: scrollEvent(dy: -1), hitLayer: nil, hitWindow: nil, session: nil))
        #expect(CATransaction.disableActions())
        CATransaction.commit()
        await waitForWheelTimer()
    }

    @Test("连续滚十格：页跟着移、当前页不变，停下到时只换到第二页")
    func wheelManyLines() async {
        let (grid, recorder) = makeRecordedGrid()
        for _ in 0..<10 {
            wheel(grid, dy: -1)
        }
        #expect(grid.layer.scrollValue == 20)
        #expect(grid.currentPageIndex == 0)
        await waitForWheelTimer()
        #expect(grid.currentPageIndex == 1)
        #expect(recorder.log == ["handler will page 1, at 20", "handler did page 1, at 1536"])
    }

    @Test("取绝对值大的增量，相等时取纵向；横向滚动也翻页")
    func wheelLargerDelta() async {
        let (grid, recorder) = makeRecordedGrid()
        wheel(grid, dx: -3, dy: 1)
        #expect(grid.layer.scrollValue == 6)
        wheel(grid, dx: 1, dy: -1)
        #expect(grid.layer.scrollValue == 8)
        wheel(grid, dx: -1)
        #expect(grid.layer.scrollValue == 10)
        await waitForWheelTimer()
        #expect(grid.currentPageIndex == 1)
        #expect(recorder.log.count == 2)
    }

    @Test("动量事件和两个增量都为 0 的事件什么都不做：不记起点、不起计时器")
    func wheelIgnored() async {
        let (grid, recorder) = makeRecordedGrid()
        grid.layer.lastTime = 7
        #expect(wheel(grid, dy: -1, momentum: 2))
        #expect(wheel(grid))
        #expect(grid.layer.scrollValue == 0)
        #expect(grid.layer.lastTime == 7)
        #expect(grid.layer.scrollWheelTimer == nil)
        await waitForWheelTimer()
        #expect(grid.currentPageIndex == 0)
        #expect(recorder.log.isEmpty)
    }

    @Test("在第一页往回滚：超过的部分只走四分之一，到时用翻页动画滑回第一页，没有回调")
    func wheelPastFirstPage() async throws {
        let window = makeWindow()
        let (grid, recorder) = makeRecordedGrid()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.layer.addSublayer(grid.layer)
        CATransaction.commit()
        defer { grid.layer.removeFromSuperlayer() }
        wheel(grid, dy: 50)
        #expect(grid.layer.scrollValue == -25)
        await waitForWheelTimer()
        #expect(grid.currentPageIndex == 0)
        #expect(grid.layer.scrollValue == 0)
        #expect(recorder.log.isEmpty)
        let animation = try #require(grid.layer.scrollLayer.animation(forKey: "bounds") as? CABasicAnimation)
        #expect((animation.fromValue as? NSValue)?.rectValue.minX == -25)
    }

    @Test("停在 0：不选页，显示第一页的位置，当前页和圆点仍是第二页")
    func wheelStopsAtZero() async {
        let (grid, recorder) = makeRecordedGrid(page: 1)
        wheel(grid, dy: 768)
        #expect(grid.layer.scrollValue == 0)
        await waitForWheelTimer()
        #expect(grid.currentPageIndex == 1)
        #expect(grid.layer.scrollValue == 0)
        #expect(dots(grid).map(\.state) == [0, 1, 0])
        #expect(recorder.log.isEmpty)
    }

    @Test("回到原位：滚动值等于开始时的值，到时退到上一页")
    func wheelBackToStart() async {
        let (grid, recorder) = makeRecordedGrid(page: 1)
        wheel(grid, dy: -10)
        wheel(grid, dy: 10)
        #expect(grid.layer.scrollValue == 1536)
        await waitForWheelTimer()
        #expect(grid.currentPageIndex == 0)
        #expect(recorder.log == ["handler will page 0, at 1536", "handler did page 0, at 0"])
    }

    @Test("从右到左：滚动位置向左移动，到时滑到第二页")
    func wheelRightToLeft() async {
        let (grid, recorder) = makeRecordedGrid(rtl: true)
        #expect(grid.layer.scrollValue == 3072)
        wheel(grid, dy: 1)
        #expect(grid.layer.scrollValue == 3070)
        await waitForWheelTimer()
        #expect(grid.currentPageIndex == 1)
        #expect(recorder.log == ["handler will page 1, at 3070", "handler did page 1, at 1536"])
    }}

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

/// A data source that only answers the page change after it happened.
@MainActor
final class DidOnlyRecorder: PageSource, ECSBDelegate {
    var pagesChangedTo: [AnyObject?] = []

    func didChangeToPage(_ page: AnyObject?) {
        pagesChangedTo.append(page)
    }
}

/// The main grid as the pager source, with the page changes it is told about recorded.
@MainActor
final class RecordingPagerSource: NSObject, ECPagerSource {
    let grid: ECSBSpringboard
    let recorder: PageChangeRecorder

    init(grid: ECSBSpringboard, recorder: PageChangeRecorder) {
        self.grid = grid
        self.recorder = recorder
    }

    func numberOfPages(for pager: ECPager) -> UInt { grid.numberOfPages(for: pager) }
    func makePage(for pager: ECPager, at index: UInt) -> ECPage? { grid.makePage(for: pager, at: index) }
    func pageItems(for pager: ECPager) -> NSArray? { grid.pageItems(for: pager) }
    func layoutPage(_ page: ECPage, for pager: ECPager) { grid.layoutPage(page, for: pager) }

    func willChangeToPageIndex(_ index: UInt) {
        let selected = grid.pager.selectedItem == nil ? "nil" : "kept"
        recorder.log.append("source will \(index), selected \(selected), at \(Int(recorder.scroll))")
    }

    func didChangeToPageIndex(_ index: UInt) {
        recorder.log.append("source did \(index), at \(Int(recorder.scroll))")
    }
}

/// A controller that opens and closes without the window, the background, the Dock or the
/// animations, recording the animations it would run.
@MainActor
final class QuietSpringboard: LPSpringboard {
    var animations: [Bool] = []

    override func _enterExitAnimation(_ enter: Bool, slow: Bool) {
        animations.append(enter)
    }

    override func orderWindowOn(_ on: Bool) {}
    override func updateDesktopImages() {}
    override func showsDock() -> Bool { false }
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

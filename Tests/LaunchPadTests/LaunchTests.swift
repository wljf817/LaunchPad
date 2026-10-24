import LaunchPadPrivate
import QuartzCore
import Testing
@testable import LaunchPad

// Pressing and launching an item (REF-LAUNCH-001 to 004, research paper §5.9), on the grid-items-still
// page laid out with the original's default geometry; events are built in the test and dispatched by
// the shared modal event controller, nothing is posted to the window server.

/// The grid-items-still page in a window's layer tree, with the original's default geometry
/// (REF-GRID-007, REF-GRID-008).
@MainActor
final class SceneGrid {
    let source: SceneDataSource
    let grid: ECSBSpringboard
    let window: WALayerKitWindow
    let top = CALayer()

    init() {
        let bundle = Bundle.module
        let fixture = try! JSONSerialization.jsonObject(with: Data(contentsOf: bundle.url(
            forResource: "grid-items-24G90", withExtension: "json", subdirectory: "Fixtures")!)) as! [String: Any]
        let geometry = try! JSONSerialization.jsonObject(with: Data(contentsOf: bundle.url(
            forResource: "grid-geometry-24G90", withExtension: "json", subdirectory: "Fixtures")!)) as! [String: Any]
        source = SceneDataSource(scene: fixture["scene"] as! [[String]])
        grid = ECSBSpringboard(handler: source, numberOfRowsPerPage: 5, numberOfColumnsPerPage: 7, scaleFactor: 1,
                               layoutRTL: false)
        let display = CGMainDisplayID()
        window = WALayerKitWindow(frame: CGDisplayBounds(display), connection: UInt32(bitPattern: CGSMainConnectionID()),
                                  display: display, tags: 0x400, level: 20)
        let saved = dockBar.display
        dockBar.display = DisplayDescriptor(notchBounds: .null)
        grid.invalidate()
        let layout = (geometry["layouts"] as! [String: Any])["default"] as! [String: Any]
        let v = (layout["pagerFrame"] as! [NSNumber]).map { CGFloat($0.doubleValue) }
        let margins = (layout["margins"] as! [NSNumber]).map { CGFloat($0.doubleValue) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        top.frame = window.layer.bounds
        window.layer.addSublayer(top)
        top.addSublayer(grid.layer)
        grid.layer.frame = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        (grid.leftMargin, grid.rightMargin, grid.topMargin, grid.bottomMargin) = (margins[0], margins[1], margins[2], margins[3])
        grid.zoomFactor = CGFloat((layout["zoomFactor"] as! NSNumber).doubleValue)
        grid.layout()
        CATransaction.commit()
        dockBar.display = saved
    }

    var page: ECSBPage { (grid.pager.pages as! [ECSBPage])[0] }

    func itemLayer(_ index: Int) -> ECSBItemLayer {
        (page.layer as! ECSBGridLayer).itemLayers[index] as! ECSBItemLayer
    }

    /// The global location of `point` in `layer`'s coordinates (REF-OVERLAY-009).
    func global(_ point: CGPoint, in layer: CALayer) -> CGPoint {
        let inRoot = layer.convert(point, to: nil)
        let frame = window.frame()
        return CGPoint(x: frame.minX + inRoot.x, y: frame.minY + frame.height - 1 - inRoot.y)
    }

    /// The centre of item `index`'s icon, in global coordinates.
    func icon(_ index: Int) -> CGPoint {
        let image = itemLayer(index).imageLayer
        return global(CGPoint(x: image.bounds.midX, y: image.bounds.midY), in: image)
    }

    /// The centre of item `index`'s name, in global coordinates.
    func name(_ index: Int) -> CGPoint {
        let label = itemLayer(index).labelLayer
        return global(CGPoint(x: label.bounds.midX, y: label.bounds.midY), in: label)
    }

    func send(_ type: CGEventType, _ location: CGPoint) {
        var windows = [window]
        var layers = [top]
        ECModalEventController.sharedController().handleEvent(mouseEvent(type, at: location), windows: &windows,
                                                              topLayers: &layers, windowCount: 1)
    }
}

/// Records the grid actions it gets.
@MainActor
final class RecordingGridActions: NSObject, ECSBGridActionHandling {
    var performed: [(index: UInt, sender: AnyObject?)] = []
    var cancelled = 0

    func performGridAction(at index: UInt, with event: ECEvent?, sender: AnyObject?) {
        performed.append((index, sender))
    }

    func cancelGridAction(with event: ECEvent?, sender: AnyObject?) {
        cancelled += 1
    }
}

/// A grid data source that records the editing callbacks.
@MainActor
final class EditingDelegate: NSObject, ECSBDataSource, ECSBDelegate {
    var calls: [String] = []

    func value(forKey key: String, ofItem item: AnyObject?, withInfo info: AnyObject?) -> AnyObject? { nil }
    func didBeginEditing() { calls.append("begin") }
    func didEndEditing() { calls.append("end") }
}

@MainActor
@Suite(.serialized) struct EditingTests {
    @Test("pager 的 editing 传给每一页，并且每次都告诉 handler")
    func pagerEditing() {
        let scene = SceneGrid()
        let delegate = EditingDelegate()
        scene.grid.pager.handler = delegate
        scene.grid.editing = true
        #expect(scene.grid.pager.editing)
        let pages = scene.grid.pager.pages as! [ECSBPage]
        #expect(pages.allSatisfy { $0.editing })
        scene.grid.editing = true
        scene.grid.editing = false
        #expect(!scene.page.editing)
        #expect(delegate.calls == ["begin", "begin", "end"])
        scene.grid.pager.handler = scene.source
        scene.grid.editing = true
        #expect(scene.grid.editing)
    }

    @Test("关闭动画开始时清掉编辑标志")
    func cleanupEndsEditing() {
        let springboard = RecordingSpringboard()
        springboard.editing = true
        #expect(springboard.springboard.pager.editing)
        springboard._cleanupBeforeExitAnimation()
        #expect(!springboard.editing)
    }

    @Test("变暗：图标 layer 套上乘色滤镜，撤销后复原，值不变时不改")
    func darkened() throws {
        let itemLayer = ECSBItemLayer(scaleFactor: 1, layoutRTL: false)
        itemLayer.darkened = true
        let filter = try #require(itemLayer.imageLayer.filters?.first as? CAFilter)
        #expect(itemLayer.imageLayer.filters?.count == 1)
        #expect(filter.value(forKey: "type") as? String == "multiplyColor")
        let color = filter.value(forKey: "inputColor") as! CGColor
        #expect(color.components == [0.4, 1])  // REF-LAUNCH-001
        itemLayer.darkened = true
        #expect(itemLayer.imageLayer.filters?.first as? CAFilter === filter)
        itemLayer.darkened = false
        #expect(itemLayer.imageLayer.filters == nil)
        #expect(!itemLayer.darkened)
    }

    @Test("disableLayout 为 YES 的 item layer 不被摆放，其余照常")
    func disableLayout() {
        let scene = SceneGrid()
        let held = scene.itemLayer(3)
        let other = scene.itemLayer(4)
        let heldPosition = held.position
        let otherPosition = other.position
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        held.position = CGPoint(x: 1, y: 1)
        other.position = CGPoint(x: 1, y: 1)
        held.disableLayout = true
        (scene.page.layer as! ECSBGridLayer)._layoutItemLayers()
        CATransaction.commit()
        #expect(held.position == CGPoint(x: 1, y: 1))
        #expect(other.position == otherPosition)
        held.disableLayout = false
        (scene.page.layer as! ECSBGridLayer)._layoutItemLayers()
        #expect(held.position == heldPosition)
    }
}

@MainActor
@Suite(.serialized) struct PressTests {
    let scene = SceneGrid()
    let actions = RecordingGridActions()
    let handler: RecordingHandler

    init() {
        handler = RecordingHandler(layer: scene.top)
        scene.grid.pager.gridActionHandler = actions
        ECModalEventController.sharedController().addHandler(handler, externalEventSource: true, usingMouseHysteresis: true)
    }

    func done() {
        ECModalEventController.sharedController().removeHandler(handler)
    }

    @Test("按下时拖动捕获记下序号、按下点和 item layer 在滚动 layer 里的 frame")
    func dragCaptureRecordsPress() throws {
        defer { done() }
        let index = 3
        let point = scene.icon(index)
        scene.send(.leftMouseDown, point)
        let capture = try #require(scene.grid.eventHandler.dragCapture)
        let state = try #require(capture.beginningState)
        #expect(state.itemIndex == UInt(index))
        #expect(state.page === scene.page)
        let scroll = scene.grid.pager.layer.scrollLayer
        let itemLayer = scene.itemLayer(index)
        let inWindow = scene.window.convertPointFromGlobal(point)
        #expect(state.location == scroll.convert(inWindow, from: nil))
        #expect(state.frame == scene.page.layer!.convert(itemLayer.frame, to: scroll))
        #expect(!capture.dragging)
        #expect(!capture.fromInLockedRange)
        #expect(capture.mainPager === scene.grid.pager)
        #expect(capture.modalEventHandler === handler)
        scene.send(.leftMouseUp, point)
    }

    @Test("pager 的 currentPage 越界时为 nil")
    func currentPage() {
        defer { done() }
        #expect(scene.grid.pager.currentPage === scene.page)
        let pages = scene.grid.pager.pages
        let saved = pages.copy() as! [AnyObject]
        pages.removeAllObjects()
        #expect(scene.grid.pager.currentPage == nil)
        pages.addObjects(from: saved)
    }

    @Test("在图标上单击：按下时变暗、pager 编辑，松开时恢复并交给 grid action handler")
    func clickIcon() {
        defer { done() }
        let index = 3
        let itemLayer = scene.itemLayer(index)
        scene.send(.leftMouseDown, scene.icon(index))
        #expect(itemLayer.darkened)
        #expect(itemLayer.disableLayout)
        #expect(scene.grid.pager.editing)
        #expect(actions.performed.isEmpty)
        scene.send(.leftMouseUp, scene.icon(index))
        #expect(!itemLayer.darkened)
        #expect(!itemLayer.disableLayout)
        #expect(actions.performed.count == 1)
        #expect(actions.performed.first?.index == UInt(index))
        #expect(actions.performed.first?.sender === scene.page)
        #expect(actions.cancelled == 0)
        #expect(scene.grid.eventHandler.dragCapture == nil)
    }

    @Test("点名称：不变暗，不交给 grid action，像点空白处一样取消")
    func clickName() {
        defer { done() }
        let itemLayer = scene.itemLayer(3)
        scene.send(.leftMouseDown, scene.name(3))
        #expect(!itemLayer.darkened)
        scene.send(.leftMouseUp, scene.name(3))
        #expect(actions.performed.isEmpty)
        #expect(actions.cancelled == 1)
    }

    @Test("在图标上按下后移动达到阈值再松开：不交给 grid action，不取消，图标恢复")
    func dragOnIcon() {
        defer { done() }
        let itemLayer = scene.itemLayer(3)
        let start = scene.icon(3)
        scene.send(.leftMouseDown, start)
        for dx in stride(from: 2.0, through: 20, by: 2) {
            scene.send(.leftMouseDragged, CGPoint(x: start.x + dx, y: start.y))
        }
        #expect(itemLayer.darkened)
        scene.send(.leftMouseUp, CGPoint(x: start.x + 20, y: start.y))
        #expect(actions.performed.isEmpty)
        #expect(actions.cancelled == 0)
        #expect(!itemLayer.darkened)
        #expect(!itemLayer.disableLayout)
    }

    @Test("在图标下边缘按下、移动不到阈值、松在名称上：取消，图标恢复")
    func slideOntoName() {
        defer { done() }
        let index = 3
        let itemLayer = scene.itemLayer(index)
        let image = itemLayer.imageLayer
        // 1 point above the icon's lower edge, then 2 points down onto the name (REF-LAUNCH-004).
        let start = scene.global(CGPoint(x: image.bounds.midX, y: image.bounds.minY + 1.5), in: image)
        scene.send(.leftMouseDown, start)
        #expect(itemLayer.darkened)
        scene.send(.leftMouseDragged, CGPoint(x: start.x, y: start.y + 1))
        scene.send(.leftMouseDragged, CGPoint(x: start.x, y: start.y + 2))
        #expect(itemLayer.darkened)
        scene.send(.leftMouseUp, CGPoint(x: start.x, y: start.y + 2))
        #expect(actions.performed.isEmpty)
        #expect(actions.cancelled == 1)
        #expect(!itemLayer.darkened)
        #expect(!itemLayer.disableLayout)
    }
}

/// An app whose bookmark resolution is recorded and finished by the test.
final class ResolvingApp: LPApp, @unchecked Sendable {
    var log: (String) -> Void = { _ in }
    var resolve: ((URL?) -> Void)?

    override func resolveURLFromBookMark(_ updateBookmark: Bool, url block: (@convention(block) (URL?) -> Void)?) {
        log("resolve \(updateBookmark)")
        resolve = block
    }
}

/// A controller that records the zoom, the close and the open instead of making them.
@MainActor
final class RecordingLPSpringboard: LPSpringboard {
    var log: [String] = []

    override func setVisible(_ visible: Bool, reason: String?) {
        log.append("visible \(visible) \(reason ?? "")")
    }

    override func performOpenAnimation(forRunnable runnable: LPRunnable?, withImage image: AnyObject?, atFrame: CGRect,
                                       toFrame: CGRect) {
        log.append("zoom \(atFrame) \(toFrame)")
    }

    override func handleRunnableOpen(_ runnable: LPRunnable?, atURL url: URL?, fromFrame: CGRect,
                                     toFrame: UnsafeMutablePointer<CGRect>?) -> Bool {
        log.append("open \(url?.path ?? "")")
        return true
    }
}

/// A grid data source that also takes the item actions.
@MainActor
final class ActingDataSource: NSObject, ECSBDataSource, ECSBActionHandling {
    let scene: SceneDataSource
    var actions: [(item: AnyObject?, sender: AnyObject?)] = []

    init(scene: SceneDataSource) {
        self.scene = scene
    }

    func value(forKey key: String, ofItem item: AnyObject?, withInfo info: AnyObject?) -> AnyObject? {
        scene.value(forKey: key, ofItem: item, withInfo: info)
    }

    func performAction(forItem item: AnyObject?, with event: ECEvent?, sender: AnyObject?) {
        actions.append((item, sender))
    }
}

@MainActor
@Suite(.serialized) struct LaunchPathTests {
    @Test("grid action 把这一项的模型对象交给 handler；图标矩形是图标 layer 在根 layer 里的 frame")
    func gridAction() throws {
        let scene = SceneGrid()
        let acting = ActingDataSource(scene: scene.source)
        scene.grid.handler = acting
        let item = try #require(scene.page.item.items?[3] as? ECSBItem)
        scene.grid.performGridAction(at: 3, with: nil, sender: scene.page)
        #expect(acting.actions.count == 1)
        #expect(acting.actions.first?.item === item.clientItem)
        #expect(acting.actions.first?.sender === scene.grid)
        scene.grid.performGridAction(at: 1000, with: nil, sender: scene.page)
        #expect(acting.actions.count == 1)
        let image = scene.itemLayer(3).imageLayer
        #expect(scene.grid.globalBoundsOfIcon(forItem: item.clientItem) == image.superlayer!.convert(image.frame, to: nil))
        #expect(scene.grid.globalBoundsOfIcon(forItem: NSObject()) == .zero)
    }

    @Test("飞出：起始值、终止的变换和透明度、时长和曲线照 REF-LAUNCH-002；目标宽高为 0 时放大 2 倍")
    func zoom() throws {
        let springboard = RecordingSpringboard()
        let root = springboard.containerWindow().layer
        let image = SceneDataSource.image(96)
        let start = CGRect(x: 363, y: 333, width: 104, height: 104)
        springboard.performOpenAnimation(forRunnable: nil, withImage: image, atFrame: start,
                                         toFrame: springboard.containerWindow().convertRectFromGlobal(.zero))
        let layer = try #require(root.sublayers?.last)
        #expect(layer.contents as AnyObject === image)
        #expect(layer.bounds.size == start.size)
        #expect(layer.position == CGPoint(x: start.midX, y: start.midY))
        #expect(CATransform3DEqualToTransform(layer.transform, CATransform3DMakeScale(2, 2, 1)))
        #expect(layer.opacity == 0.1)
        let opacity = try #require(layer.animation(forKey: "opacity") as? CABasicAnimation)
        #expect(opacity.fromValue as? Float == 0.9)
        #expect(opacity.duration == 0.25)
        #expect(opacity.timingFunction == CAMediaTimingFunction(name: .easeOut))
        let transform = try #require(layer.animation(forKey: "transform") as? CABasicAnimation)
        #expect(CATransform3DEqualToTransform((transform.fromValue as! NSValue).caTransform3DValue, CATransform3DIdentity))
        #expect(layer.animation(forKey: "position") == nil)
        layer.removeFromSuperlayer()
    }

    @Test("LPSpringboard：先飞出、关闭，再解析书签；找得到时打开，notFound 时不打开")
    func launchOrder() async {
        let springboard = RecordingLPSpringboard()
        let app = ResolvingApp(forCopy: ())
        app._icon = SceneDataSource.image(96)
        app.log = { springboard.log.append($0) }
        let rect = CGRect(x: 363, y: 333, width: 104, height: 104)
        springboard._launchRunnable(app, withImageRect: rect, withEvent: nil)
        let target = springboard.containerWindow().convertRectFromGlobal(.zero)
        #expect(springboard.log == ["zoom \(rect) \(target)", "visible false launch runnable in LPSpringboard subclass", "resolve true"])
        app.resolve?(URL(fileURLWithPath: "/System/Applications/Calculator.app"))
        await drainMainQueue()
        #expect(springboard.log.last == "open /System/Applications/Calculator.app")

        springboard.log = []
        app.notFound = true
        springboard._launchRunnable(app, withImageRect: rect, withEvent: nil)
        app.resolve?(URL(fileURLWithPath: "/System/Applications/Calculator.app"))
        await drainMainQueue()
        #expect(!springboard.log.contains { $0.hasPrefix("open") })
    }

    @Test("没有图标时不飞出，照常关闭和解析书签")
    func launchWithoutIcon() {
        let springboard = RecordingLPSpringboard()
        let app = ResolvingApp(forCopy: ())
        app.log = { springboard.log.append($0) }
        springboard._launchRunnable(app, withImageRect: .zero, withEvent: nil)
        #expect(springboard.log == ["visible false launch runnable in LPSpringboard subclass", "resolve true"])
    }

    @Test("打开应用的参数：标志和 disp 记录照 REF-LAUNCH-003")
    func launchParametersMatch() throws {
        let (flags, params) = launchParameters(dontSwitch: false, slow: false, display: 1)
        #expect(flags == 0x45)
        let record = try #require(params)
        #expect(record.descriptorType == 0x7265_636F)  // 'reco'
        #expect(record.numberOfItems == 1)
        let disp = try #require(record.forKeyword(0x6469_7370))
        #expect(disp.descriptorType == 0x6C6F_6E67)  // 'long'
        #expect(disp.int32Value == 1)
        #expect(launchParameters(dontSwitch: false, slow: true, display: 1).0 == 0x100_0045)
        #expect(launchParameters(dontSwitch: true, slow: false, display: 1).0 == 0x245)
        #expect(launchParameters(dontSwitch: false, slow: false, display: 0).1 == nil)
    }
}

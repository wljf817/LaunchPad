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

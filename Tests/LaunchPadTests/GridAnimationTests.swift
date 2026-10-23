import Foundation
import QuartzCore
import Testing
@testable import LaunchPad

/// Opening and closing as they touch the main grid: the icon cache switch and the purge after a close
/// (REF-GRID-015), the visibility passed down the grid, and the main grid's zoom (REF-OVERLAY-001,
/// REF-OVERLAY-004, REF-OVERLAY-008).
@MainActor
@Suite(.serialized)
struct GridAnimationTests {
    // MARK: - The cache switch (REF-GRID-015)

    @Test("布局根的值变了才往下设，深度优先设给所有子项")
    func rootPassesOnChangesOnly() throws {
        let root = LPRoot()
        let page = LPPage(items: nil)
        root.children.add(page)
        let app = makeTestApp("Top")
        let folder = LPGroup(groupWithTitle: "Folder", andChildren: nil)
        let folderPage = LPPage(items: nil)
        let inner = makeTestApp("Inner")
        page.children.add(app)
        page.children.add(folder)
        folder.children.add(folderPage)
        folderPage.children.add(inner)

        root.setShouldCacheIcons(true)
        #expect(root._shouldCacheIcons)
        #expect(page._shouldCacheIcons && app._shouldCacheIcons && folder._shouldCacheIcons && folderPage._shouldCacheIcons && inner._shouldCacheIcons)

        // The same value again is not passed on.
        app._shouldCacheIcons = false
        root.setShouldCacheIcons(true)
        #expect(!app._shouldCacheIcons)

        root.setShouldCacheIcons(false)
        #expect(!root._shouldCacheIcons && !page._shouldCacheIcons && !app._shouldCacheIcons && !inner._shouldCacheIcons)
    }

    @Test("应用设为 NO 时清掉自己的图标，进程内缓存里的还在")
    func runnableDropsOwnIcons() throws {
        let app = makeTestApp("Purged")
        app.setShouldCacheIcons(true)
        let icon = try #require(solidImage(96))
        let mini = try #require(solidImage(22))
        app.icon = icon
        app.miniIcon = mini
        #expect(app._icon === icon && app._miniIcon === mini)

        app.setShouldCacheIcons(false)
        #expect(app._icon == nil && app._miniIcon == nil)
        #expect(app.icon === icon)
        #expect(app.miniIcon === mini)
        #expect(app._icon == nil)
        app.icon = nil
        app.miniIcon = nil
    }

    // MARK: - Visibility and purging down the grid (REF-GRID-015)

    let geometry: [String: Any] = {
        let url = Bundle.module.url(forResource: "grid-geometry-24G90", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }()

    /// A one-page grid with two apps and a folder of two, laid out with the original's default
    /// geometry, so that every item layer has its contents.
    func makeGrid() -> (ECSBSpringboard, SceneDataSource) {
        let source = SceneDataSource(scene: [["A"], ["B"], ["C", "F"], ["D", "F"]])
        let grid = ECSBSpringboard(handler: source, numberOfRowsPerPage: 5, numberOfColumnsPerPage: 7, scaleFactor: 1,
                                   layoutRTL: false)
        let saved = dockBar.display
        defer { dockBar.display = saved }
        dockBar.display = DisplayDescriptor(notchBounds: .null)
        grid.invalidate()
        let layout = (geometry["layouts"] as! [String: Any])["default"] as! [String: Any]
        let frame = (layout["pagerFrame"] as! [NSNumber]).map { CGFloat($0.doubleValue) }
        let margins = (layout["margins"] as! [NSNumber]).map { CGFloat($0.doubleValue) }
        grid.layer.frame = CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3])
        (grid.leftMargin, grid.rightMargin, grid.topMargin, grid.bottomMargin) = (margins[0], margins[1], margins[2], margins[3])
        grid.zoomFactor = CGFloat((layout["zoomFactor"] as! NSNumber).doubleValue)
        grid.layout()
        return (grid, source)
    }

    func itemLayers(_ grid: ECSBSpringboard) throws -> [ECSBItemLayer] {
        let page = try #require((grid.pager.pages as? [ECSBPage])?.first)
        return try #require((page.layer as? ECSBGridLayer)?.itemLayers as? [ECSBItemLayer])
    }

    /// Records the implicit actions a layer asks for, with the transaction's duration and timing
    /// function at that moment. Core Animation asks only while actions are enabled; in a test process
    /// it adds no implicit animation itself.
    final class ActionRecorder: NSObject, CALayerDelegate {
        var events: [(key: String, duration: CFTimeInterval, timing: CAMediaTimingFunction?)] = []
        func action(for layer: CALayer, forKey event: String) -> CAAction? {
            events.append((event, CATransaction.animationDuration(), CATransaction.animationTimingFunction()))
            return nil
        }
    }

    @Test("显示状态从 ECSBSpringboard 传到 pager 和每个 item layer，值变了才传")
    func visibilityGoesDown() throws {
        let (grid, _) = makeGrid()
        let layers = try itemLayers(grid)
        #expect(layers.count == 3)
        grid.setVisible(true)
        #expect(grid.visible && grid.pager.visible)
        let allVisible = layers.allSatisfy { $0.visible }
        #expect(allVisible)
        // Unchanged values are not passed on.
        layers[0].setVisible(false)
        grid.setVisible(true)
        #expect(!layers[0].visible)
        grid.setVisible(false)
        #expect(!grid.visible && !grid.pager.visible)
        let restHidden = layers.dropFirst().allSatisfy { !$0.visible }
        #expect(restHidden)
    }

    @Test("释放清掉每个 item layer 的图标和文件夹的小图标，名称不变，没有隐式动画")
    func purgeDropsIcons() throws {
        let (grid, _) = makeGrid()
        let layers = try itemLayers(grid)
        let folder = try #require(layers[2] as? ECSBGroupItemLayer)
        #expect(layers[0].imageLayer.contents != nil)
        #expect(folder.miniGridLayer.numberOfItems == 2)
        #expect(folder.miniGridLayer.itemLayer(at: 0)?.contents != nil)
        let titles = layers.map { $0.labelLayer.string as? String }

        // The current page is skipped when asked to.
        grid.purgeItemContents(true)
        #expect(layers[0].imageLayer.contents != nil)

        let recorder = ActionRecorder()
        let minis = (0..<folder.miniGridLayer.numberOfItems).compactMap { folder.miniGridLayer.itemLayer(at: $0) }
        #expect(minis.count == 2)
        for layer in layers.map(\.imageLayer) + minis {
            layer.delegate = recorder
        }
        grid.purgeItemContents(false)
        for layer in layers {
            #expect(layer.imageLayer.contents == nil)
        }
        for mini in minis {
            #expect(mini.contents == nil)
        }
        #expect(recorder.events.isEmpty)
        #expect(layers.map { $0.labelLayer.string as? String } == titles)
    }

    func solidImage(_ size: Int) -> CGImage? {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context?.makeImage()
    }
}

import CoreText
import Foundation
import ImageIO
import LaunchPadPrivate
import QuartzCore
import Testing
@testable import LaunchPad

/// The items' icons, names and folder icons (REF-GRID-010 to 014), checked against the item layer
/// subtrees the original showed on the grid-items-still page (`Fixtures/grid-items-24G90.json`), and
/// the logic that gets the icons there.
@MainActor
@Suite(.serialized)
struct GridItemsTests {
    let fixture: [String: Any] = {
        let url = Bundle.module.url(forResource: "grid-items-24G90", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }()

    let geometry: [String: Any] = {
        let url = Bundle.module.url(forResource: "grid-geometry-24G90", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }()

    // MARK: - Item layers against the original (REF-GRID-010, REF-GRID-011, REF-GRID-013)

    @Test("每个 item layer 以下各 layer 的 frame 和属性与原版的导出相同")
    func itemLayersLeftToRight() throws {
        try expectSceneItems(layoutRTL: false, measured: fixture["leftToRight"] as! [[String: Any]])
    }

    @Test("从右到左时 item layer 以下各 layer 与原版的导出相同")
    func itemLayersRightToLeft() throws {
        try expectSceneItems(layoutRTL: true, measured: fixture["rightToLeft"] as! [[String: Any]])
    }

    /// Builds the scene's page with the original's default geometry (REF-GRID-007, 008) and compares
    /// every item layer subtree.
    func expectSceneItems(layoutRTL: Bool, measured: [[String: Any]]) throws {
        let source = SceneDataSource(scene: fixture["scene"] as! [[String]])
        let grid = ECSBSpringboard(handler: source, numberOfRowsPerPage: 5, numberOfColumnsPerPage: 7, scaleFactor: 1,
                                   layoutRTL: layoutRTL)
        let saved = dockBar.display
        defer { dockBar.display = saved }
        dockBar.display = DisplayDescriptor(notchBounds: .null)
        grid.invalidate()
        let layout = (geometry["layouts"] as! [String: Any])["default"] as! [String: Any]
        let margins = (layout["margins"] as! [NSNumber]).map { CGFloat($0.doubleValue) }
        grid.layer.frame = rect(layout["pagerFrame"])
        (grid.leftMargin, grid.rightMargin, grid.topMargin, grid.bottomMargin) = (margins[0], margins[1], margins[2], margins[3])
        grid.zoomFactor = CGFloat((layout["zoomFactor"] as! NSNumber).doubleValue)
        grid.layout()
        let page = try #require((grid.pager.pages as? [ECSBPage])?.first)
        let gridLayer = try #require(page.layer as? ECSBGridLayer)
        let itemLayers = try #require(gridLayer.itemLayers as? [CALayer])
        #expect(itemLayers.count == measured.count)
        for (index, (itemLayer, expected)) in zip(itemLayers, measured).enumerated() {
            expectLayer(itemLayer, expected, "item \(index)")
        }
    }

    func expectLayer(_ layer: CALayer, _ expected: [String: Any], _ path: String) {
        #expect(NSStringFromClass(type(of: layer)) == expected["class"] as! String, "\(path)")
        #expect(layer.frame == rect(expected["frame"]), "\(path) frame")
        let origin = (expected["boundsOrigin"] as! [NSNumber]).map { CGFloat($0.doubleValue) }
        #expect(layer.bounds.origin == CGPoint(x: origin[0], y: origin[1]), "\(path) bounds origin")
        #expect(layer.isHidden == expected["hidden"] as! Bool, "\(path) hidden")
        #expect(Double(layer.opacity) == (expected["opacity"] as! NSNumber).doubleValue, "\(path) opacity")
        #expect(Double(layer.cornerRadius) == (expected["cornerRadius"] as! NSNumber).doubleValue, "\(path) corner radius")
        #expect(layer.cornerCurve.rawValue == expected["cornerCurve"] as! String, "\(path) corner curve")
        #expect(layer.contentsGravity.rawValue == expected["contentsGravity"] as! String, "\(path) gravity")
        #expect(Double(layer.contentsScale) == (expected["contentsScale"] as! NSNumber).doubleValue, "\(path) contents scale")
        #expect(layer.masksToBounds == expected["masksToBounds"] as! Bool, "\(path) masks")
        #expect(layer.allowsHitTesting == expected["allowsHitTesting"] as! Bool, "\(path) hit testing")
        #expect(layer.allowsGroupBlending == expected["allowsGroupBlending"] as! Bool, "\(path) group blending")
        #expect(layer.contentsCenter == rect(expected["contentsCenter"]), "\(path) contents center")
        #expect(layer.name == expected["name"] as? String, "\(path) name")
        if let color = expected["backgroundColor"] as? [NSNumber] {
            #expect(layer.backgroundColor?.components?.map(Double.init) == color.map(\.doubleValue), "\(path) background")
        } else {
            #expect(layer.backgroundColor == nil, "\(path) background")
        }
        #expect((layer.compositingFilter != nil) == (expected["compositingFilter"] != nil), "\(path) compositing")
        if let size = expected["contentsSize"] as? [NSNumber] {
            let image = layer.contents.map { $0 as! CGImage }
            #expect(image?.width == size[0].intValue && image?.height == size[1].intValue, "\(path) contents size")
        }
        if let text = expected["text"] as? [String: Any], let textLayer = layer as? CATextLayer {
            #expect(textLayer.string as? String == text["string"] as? String, "\(path) string")
            let font = textLayer.font.map { $0 as! CTFont }
            #expect(font.map { CTFontCopyPostScriptName($0) as String } == text["font"] as? String, "\(path) font")
            #expect(Double(textLayer.fontSize) == (text["fontSize"] as! NSNumber).doubleValue, "\(path) font size")
            #expect(textLayer.foregroundColor?.components?.map(Double.init) == (text["foreground"] as! [NSNumber]).map(\.doubleValue),
                    "\(path) foreground")
            #expect(textLayer.alignmentMode.rawValue == text["alignment"] as! String, "\(path) alignment")
            #expect(textLayer.truncationMode.rawValue == text["truncation"] as! String, "\(path) truncation")
            #expect(textLayer.isWrapped == text["wrapped"] as! Bool, "\(path) wrapped")
        }
        if let shadow = expected["textShadow"] as? [String: Any], let textLayer = layer as? ECShadowTextLayer {
            let color = textLayer.textShadowColor.map { $0 as! CGColor }
            #expect(color?.components?.map(Double.init) == (shadow["color"] as! [NSNumber]).map(\.doubleValue), "\(path) shadow color")
            let offset = (shadow["offset"] as! [NSNumber]).map { CGFloat($0.doubleValue) }
            #expect(textLayer.textShadowOffset == CGSize(width: offset[0], height: offset[1]), "\(path) shadow offset")
            #expect(Double(textLayer.textShadowBlur) == (shadow["blur"] as! NSNumber).doubleValue, "\(path) shadow blur")
            #expect(textLayer.textShadowHidden == shadow["hidden"] as! Bool, "\(path) shadow hidden")
        }
        let sublayers = layer.sublayers ?? []
        let expectedSublayers = expected["sublayers"] as! [[String: Any]]
        #expect(sublayers.count == expectedSublayers.count, "\(path) sublayers")
        for (index, (sublayer, expectedSublayer)) in zip(sublayers, expectedSublayers).enumerated() {
            expectLayer(sublayer, expectedSublayer, "\(path).\(index)")
        }
    }

    func rect(_ value: Any?) -> CGRect {
        let v = (value as! [NSNumber]).map { CGFloat($0.doubleValue) }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }

    // MARK: - The model's icons (REF-GRID-012)

    @Test("图标放进进程内的缓存，_shouldCacheIcons 为 NO 时模型对象不另外持有")
    func iconCache() throws {
        let app = makeTestApp("Cached")
        let icon = try #require(solidImage(96))
        app.icon = icon
        #expect(LPRunnable.iconCache.object(forKey: app.uuid! as NSString) === icon)
        #expect(app._icon == nil)
        #expect(app.icon === icon)
        app.setShouldCacheIcons(true)
        #expect(app.icon === icon)
        #expect(app._icon === icon)
        let mini = try #require(solidImage(22))
        app.miniIcon = mini
        #expect(app._miniIcon === mini)
        // The original keeps the item's own mini icon when the mini icon is set to nil.
        app.miniIcon = nil
        #expect(LPRunnable.miniIconCache.object(forKey: app.uuid! as NSString) == nil)
        #expect(app._miniIcon === mini)
        app.icon = nil
        #expect(app._icon == nil)
        #expect(LPRunnable.iconCache.object(forKey: app.uuid! as NSString) == nil)
    }

    @Test("写库存宽度和 PNG；读库建模型时图标进缓存；缓存里没有时从库里读")
    func iconStorage() async throws {
        let directory = TemporaryDirectory()
        let path = directory.path("db")
        let bundle = try makeAppBundle(at: directory.path("Stored.app"), bundleID: "com.example.stored")
        let (storage, root, _, _) = await openStorage(at: path)
        let page = LPPage(items: nil)
        try #require(root).children.add(page)
        let app = try #require(LPApp(url: bundle, forScan: 1))
        page.children.add(app)
        app.icon = try #require(solidImage(96))
        app.miniIcon = try #require(solidImage(22))
        app.updateImageStorage()
        storage.markInitialSetupComplete()
        await waitForDatabase(storage)
        let rows = queryRows(path, "SELECT size_big, size_mini, image_data, image_data_mini FROM image_cache")
        let row = try #require(rows.first)
        #expect(row["size_big"] as? Int64 == 96 && row["size_mini"] as? Int64 == 22)
        let data = try #require(row["image_data"] as? Data)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")

        // A miss reads the database, and the image arrives on the main queue.
        LPRunnable.iconCache.removeObject(forKey: app.uuid! as NSString)
        #expect(app.icon == nil)
        #expect(app.loadingLarge)
        await waitForDatabase(storage)
        await drainMainQueue()
        let loaded = try #require(LPRunnable.iconCache.object(forKey: app.uuid! as NSString))
        #expect((loaded as! CGImage).width == 96)
        #expect(!app.loadingLarge)

        // Reading the database again puts both icons into the caches with their sizes.
        LPRunnable.iconCache.removeObject(forKey: app.uuid! as NSString)
        LPRunnable.miniIconCache.removeObject(forKey: app.uuid! as NSString)
        let (_, reread, _, _) = await openStorage(at: path, readOnly: true)
        let copy = try #require(((reread?.children.firstObject as? LPPage)?.children.firstObject) as? LPRunnable)
        #expect(copy.largeIconSize == 96 && copy.miniIconSize == 22)
        #expect((LPRunnable.iconCache.object(forKey: copy.uuid! as NSString) as! CGImage?)?.width == 96)
        #expect((LPRunnable.miniIconCache.object(forKey: copy.uuid! as NSString) as! CGImage?)?.width == 22)
    }

    @Test("生成的图标与直接用 IconServices 画出的逐像素相同，取完后写库；尺寸没变时不再生成")
    func iconGeneration() async throws {
        let directory = TemporaryDirectory()
        let path = directory.path("db")
        let (storage, root, _, _) = await openStorage(at: path)
        let page = LPPage(items: nil)
        try #require(root).children.add(page)
        let url = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let app = try #require(LPApp(url: url, forScan: 1))
        page.children.add(app)
        app.retrieveImageOfLargeSize(96, andMiniSize: 22)
        let count = app.loadingCounter.load(ordering: .sequentiallyConsistent)
        await waitForIconGeneration(storage)
        let icon = try #require(app.icon as! CGImage?)
        let mini = try #require(app.miniIcon as! CGImage?)
        #expect(icon.width == 96 && mini.width == 22)
        #expect(pixels(icon) == pixels(directIcon(url, 96)))
        #expect(pixels(mini) == pixels(directIcon(url, 22)))
        let row = try #require(queryRows(path, "SELECT size_big, size_mini, image_data FROM image_cache").first)
        #expect(row["size_big"] as? Int64 == 96 && row["size_mini"] as? Int64 == 22)
        #expect(row["image_data"] as? Data != nil)
        app.retrieveImageOfLargeSize(96, andMiniSize: 22)
        #expect(app.loadingCounter.load(ordering: .sequentiallyConsistent) == count)
    }

    /// The app's icon drawn the way the original draws it, but into a plain bitmap context.
    func directIcon(_ url: URL, _ size: Int) -> CGImage? {
        guard let binding = _LSBindingCreateWithURL(nil, url as CFURL),
              let image = ISCreateCGImageFromBindingWithSizeScaleAndOptions(binding, CGSize(width: size, height: size), 1, nil),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: 0x2002) else { return nil }
        CGContextSetCompositeOperation(context, 1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()
    }

    // MARK: - The placeholder (REF-GRID-012)

    @Test("没有图标时的占位图：按尺寸和缩放比渲染，同一个键取到同一个渲染对象")
    func placeholder() throws {
        let entry = try #require(ECSizedIconImageCache.entry(withIcon: nil, forSize: 96, andScaleFactor: 1))
        #expect(entry.width == 96 && entry.height == 96)
        let image = try #require(entry.image as! CGImage?)
        #expect(image.width == 96)
        let again = try #require(ECSizedIconImageCache.entry(withIcon: nil, forSize: 96, andScaleFactor: 1))
        #expect(again._render === entry._render)
        #expect(pixels(image)?.contains { $0 != 0 } == true)
        #expect(pixels(image) == pixels(directPlaceholder(96, 1)))
        let value = try #require(entry.CA_copyRenderValue())
        CARenderRelease(value)
        let doubled = try #require(ECSizedIconImageCache.entry(withIcon: nil, forSize: 22, andScaleFactor: 2))
        #expect(doubled.width == 44)
        #expect(pixels(doubled.image as! CGImage?) == pixels(directPlaceholder(22, 2)))
        // As a layer's contents, the entry shows the rendered image.
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 96, height: 96)
        layer.contents = entry
        #expect(pixels(rendered(layer)) == pixels(image))
        // An icon that is not cached is not rendered.
        let binding = try #require(_LSBindingCreateWithURL(nil, URL(fileURLWithPath: "/System/Applications/Calculator.app") as CFURL))
        #expect(ECSizedIconImageCache.entry(withIcon: binding, forSize: 96, andScaleFactor: 1) == nil)
    }

    /// The default binding's image drawn the way REF-GRID-012 describes, into a plain bitmap context.
    func directPlaceholder(_ size: Int, _ scale: Int) -> CGImage? {
        let icon = ISIcon(binding: _LSBindingCreateWithTypeInfo(nil, 0, 0x6e6c6464, nil, 0)!)
        let descriptor = ISImageDescriptor(size: CGSize(width: size, height: size), scale: CGFloat(scale))
        descriptor.backgroundStyle = dockGlobals.darkDock ? 1 : 0
        icon.prepareImages(for: [descriptor])
        guard let image = icon.image(for: descriptor)?.cgImage,
              let context = CGContext(data: nil, width: size * scale, height: size * scale, bitsPerComponent: 8,
                                      bytesPerRow: size * scale * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: 0x2002) else { return nil }
        CGContextSetCompositeOperation(context, 1)
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()
    }

    /// A layer drawn by Core Animation into a bitmap of its size.
    func rendered(_ layer: CALayer) -> CGImage? {
        let width = Int(layer.bounds.width), height = Int(layer.bounds.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: 0x2002) else { return nil }
        layer.render(in: context)
        return context.makeImage()
    }

    // MARK: - The controller (REF-GRID-014)

    @Test("启动时每一项只登记一次；关着时记下变化，开着时交给界面，补上以后清空")
    func refresh() async throws {
        let startup = StartupTests()
        await startup.makeDatabase()
        let springboard = try await startup.launch(injecting: StartupTests.goldenApps())
        var count = 0
        springboard.rootPage?.iterateChildren { _, _ in count += 1 }
        #expect(springboard.observedItems?.count == count)
        let app = try #require(firstApp(springboard.rootPage))
        #expect(!springboard.registerObservationOfItem(app))

        // Closed: the change is noted.
        app.title = "Renamed"
        #expect(springboard.staleProperties?.object(forKey: app)?.contains("title") == true)
        let itemLayer = try #require(springboard.springboard.item(forClientItem: app)?.itemLayer)
        #expect(itemLayer.title as String? != "Renamed")

        // Open: the noted change reaches the item layer, and the table is emptied.
        springboard._visible = true
        defer { springboard._visible = false }
        springboard.processPendingUpdates()
        #expect(itemLayer.title as String? == "Renamed")
        #expect(springboard.staleProperties?.count == 0)

        // Open: a change goes straight to the item layer.
        app.title = "Again"
        #expect(itemLayer.title as String? == "Again")
    }

    @Test("数据源只在打开时给图标，没有图标时给占位图")
    func iconsOnlyWhileOpen() async throws {
        let startup = StartupTests()
        await startup.makeDatabase()
        let springboard = try await startup.launch()
        let app = try #require(firstApp(springboard.rootPage))
        #expect(springboard.value(forKey: "icon", ofItem: app, withInfo: nil) == nil)
        springboard._visible = true
        defer { springboard._visible = false }
        LPRunnable.iconCache.removeObject(forKey: app.uuid! as NSString)
        app._icon = nil
        let placeholder = try #require(springboard.value(forKey: "icon", ofItem: app, withInfo: nil) as! CGImage?)
        let scale = UInt(Springboard.scaleFactor(of: springboard.display()))
        #expect(UInt(placeholder.width) == springboard.iconSize * scale)
        #expect(springboard.value(forKey: "title", ofItem: app, withInfo: nil) as? String == app.title)
    }

    func firstApp(_ root: LPRoot?) -> LPApp? {
        var found: LPApp?
        root?.iterateChildren { item, stop in
            if found == nil, let app = item as? LPApp {
                found = app
                stop.pointee = true
            }
        }
        return found
    }

    // MARK: -

    func solidImage(_ size: Int) -> CGImage? {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: 0x2002)
        context?.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context?.makeImage()
    }

    func pixels(_ image: CGImage?) -> [UInt8]? {
        guard let image else { return nil }
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &buffer, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: 0x2002)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }
}

/// A data source for one page of the scene (`grid-items-scene.tsv`): apps and folders with their
/// titles, a 96-pixel icon and a 22-pixel mini icon each.
@MainActor
final class SceneDataSource: NSObject, ECSBDataSource {
    final class Node: NSObject {
        let title: String
        let kind: String
        var children: [Node] = []
        init(title: String, kind: String) {
            self.title = title
            self.kind = kind
        }
    }

    let pages: [Node]
    let icon: CGImage
    let miniIcon: CGImage

    init(scene: [[String]]) {
        let page = Node(title: "", kind: "page")
        var folder: Node?
        for row in scene {
            if row.count > 1, !row[1].isEmpty {
                if folder?.title != row[1] {
                    let group = Node(title: row[1], kind: "group")
                    group.children = [Node(title: "", kind: "page")]
                    page.children.append(group)
                    folder = group
                }
                folder?.children[0].children.append(Node(title: row[0], kind: "item"))
            } else {
                folder = nil
                page.children.append(Node(title: row[0], kind: "item"))
            }
        }
        pages = [page]
        icon = Self.image(96)
        miniIcon = Self.image(22)
    }

    static func image(_ size: Int) -> CGImage {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: 0x2002)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }

    func value(forKey key: String, ofItem item: AnyObject?, withInfo info: AnyObject?) -> AnyObject? {
        guard let node = item as? Node else {
            return key == "items" ? pages as NSArray : nil
        }
        switch key {
        case "items": return node.children as NSArray
        case "kind": return node.kind as NSString
        case "title": return node.title as NSString
        case "icon": return node.kind == "item" ? icon : nil
        case "miniIcon": return miniIcon
        default: return nil
        }
    }
}

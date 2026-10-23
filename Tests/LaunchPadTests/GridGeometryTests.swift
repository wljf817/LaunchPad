import CoreText
import Foundation
import LaunchPadPrivate
import QuartzCore
import Testing
@testable import LaunchPad

/// The grid geometry (REF-GRID-004 to 009), checked against the values the original returned and
/// laid out in the reference VM (`Fixtures/grid-geometry-24G90.json`: a sample of the class-method
/// tables and the layouts recorded under several Dock settings).
@MainActor
@Suite(.serialized)
struct GridGeometryTests {
    let fixture: [String: Any] = {
        let url = Bundle.module.url(forResource: "grid-geometry-24G90", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }()

    func rows(_ table: String) -> [[Double]] {
        let rows = (fixture[table] as! [String: Any])["rows"] as! [[Any]]
        return rows.map { $0.map { ($0 as! NSNumber).doubleValue } }
    }

    func layout(_ name: String) -> [String: Any] {
        (fixture["layouts"] as! [String: Any])[name] as! [String: Any]
    }

    func rect(_ value: Any?) -> CGRect {
        let v = (value as! [NSNumber]).map { CGFloat($0.doubleValue) }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }

    func numbers(_ value: Any?) -> [CGFloat] {
        (value as! [NSNumber]).map { CGFloat($0.doubleValue) }
    }

    // MARK: - Class methods (REF-GRID-006)

    @Test("标签字体与原版相同")
    func labelFont() {
        let font = ECSBEnvironment.shared.labelFont
        let expected = fixture["font"] as! [String: Any]
        #expect(CTFontCopyPostScriptName(font) as String == expected["postScriptName"] as! String)
        // The recorded metrics as JSON numbers, which may come back a last digit off.
        let metrics = ["size", "ascent", "descent", "leading"].map { (expected[$0] as! NSNumber).doubleValue }
        let actual = [CTFontGetSize(font), CTFontGetAscent(font), CTFontGetDescent(font), CTFontGetLeading(font)]
        #expect(zip(actual, metrics).allSatisfy { abs($0 - $1) < 1e-9 }, "\(actual) \(metrics)")
        // REF-GRID-006: the names' line is 16 points.
        #expect(textHeight(font, size: 13) == 16)
    }

    @Test("主网格算图标尺寸的类方法与原版的返回值相同")
    func springboardIconSize() {
        for row in rows("springboard") {
            for method in [ECSBSpringboard.calculateIconSize, ECSBLayer.calculateIconSize] {
                var icon: UInt = 0
                var mini: UInt = 0
                method(&icon, &mini, CGRect(x: row[0], y: row[1], width: row[2], height: row[3]), Float(row[4]),
                       row[5], row[6], row[7], row[8], Int(row[9]), row[10], UInt(row[11]), UInt(row[12]))
                #expect([Double(icon), Double(mini)] == Array(row[13...14]), "\(row)")
            }
        }
    }

    @Test("网格 layer 算图标尺寸和位置的类方法与原版的返回值相同")
    func gridIconSize() {
        for row in rows("grid") {
            let bounds = CGRect(x: 0, y: 0, width: row[0], height: row[1])
            var icon: UInt = 0
            var mini: UInt = 0
            ECSBGridLayer.calculateIconSize(&icon, miniIconSize: &mini, forBounds: bounds, andScaleFactor: Float(row[4]),
                                            withNumberOfRows: UInt(row[2]), andColumns: UInt(row[3]))
            var frame = CGRect(x: -1, y: -1, width: -1, height: -1)
            var itemBounds = CGRect(x: -7, y: -7, width: -7, height: -7)
            ECSBGridLayer.calculateIconFrame(&frame, itemBounds: &itemBounds, forBounds: bounds, andScaleFactor: Float(row[4]),
                                             withNumberOfRows: UInt(row[2]), andColumns: UInt(row[3]))
            #expect([Double(icon), Double(mini)] == Array(row[5...6]), "\(row)")
            #expect(frame == CGRect(x: row[7], y: row[8], width: row[9], height: row[10]), "\(row)")
            #expect(itemBounds == CGRect(x: row[11], y: row[12], width: row[13], height: row[14]), "\(row)")
        }
    }

    @Test("item layer 算图标尺寸和位置的类方法与原版的返回值相同")
    func itemIconSize() {
        for row in rows("item") {
            let bounds = CGRect(x: 0, y: 0, width: row[0], height: row[1])
            var icon: UInt = 0
            var mini: UInt = 0
            ECSBItemLayer.calculateIconSize(&icon, miniIconSize: &mini, forBounds: bounds, andScaleFactor: Float(row[2]))
            var frame = CGRect(x: -1, y: -1, width: -1, height: -1)
            ECSBItemLayer.calculateIconFrame(&frame, forBounds: bounds, andScaleFactor: Float(row[2]))
            #expect([Double(icon), Double(mini)] == Array(row[3...4]), "\(row)")
            #expect(frame == CGRect(x: row[5], y: row[6], width: row[7], height: row[8]), "\(row)")
        }
    }

    @Test("文件夹里小图标的尺寸与原版的返回值相同")
    func miniIconSize() {
        for row in rows("mini") {
            let size = ECSBGroupItemLayer.miniIconSize(forBounds: CGRect(x: 0, y: 0, width: row[0], height: row[0]),
                                                       andScaleFactor: Float(row[1]))
            #expect(Double(size) == row[2], "\(row)")
        }
        for row in rows("imageGrid") {
            let size = ECImageGridLayer.iconSize(forBounds: CGRect(x: 1, y: 2, width: 50, height: row[0]),
                                                 withNumberOfRows: UInt(row[1]), andColumns: UInt(row[2]),
                                                 withSpacing: UInt(row[3]))
            #expect(Double(size) == row[4], "\(row)")
        }
    }

    // MARK: - Zoom (REF-GRID-005)

    @Test("缩放系数按显示器宽度和 Dock 方向取值")
    func zoomFactorFromPrefs() async throws {
        let springboard = try await launch()
        let width = springboard.totalScreenBounds().width
        // REF-GRID-005, for the display and the Dock the tests run with.
        let base: CGFloat = width > 1920 ? 0.6 : width > 1680 ? 0.3 : width > 1440 ? 0.2 : 0
        let expected = base > 0.1 && dockBar.barOrientation != 0 ? base - 0.1 : base
        #expect(springboard.getZoomFactorFromPrefs() == expected)
    }

    @Test("调整后的边距与原版相同，缩放系数限在 0 到 1")
    func adjustedMargins() async throws {
        let springboard = try await launch()
        let layer = springboard.springboard.layer
        for name in ["start", "default", "left", "tile16"] {
            let measured = layout(name)
            let margins = numbers(measured["margins"])
            layer.frame = rect(measured["pagerFrame"])
            (layer.leftMargin, layer.rightMargin, layer.topMargin, layer.bottomMargin) = (margins[0], margins[1], margins[2], margins[3])
            layer.zoomFactor = CGFloat((measured["zoomFactor"] as! NSNumber).doubleValue)
            #expect([layer.adjustedLeftMargin(), layer.adjustedRightMargin(), layer.adjustedTopMargin(),
                     layer.adjustedBottomMargin()] == numbers(measured["adjusted"]), "\(name)")
        }
        layer.zoomFactor = -1
        #expect(layer.zoomFactor == 0)
        layer.zoomFactor = 2
        #expect(layer.zoomFactor == 1)
    }

    // MARK: - Pages and cells (REF-GRID-007, REF-GRID-008)

    /// Lays out the main grid from the pager layer down with the frame, margins and zoom factor
    /// measured in the original, on a display without a notch like the reference VM's.
    func layOut(_ grid: ECSBSpringboard, as measured: [String: Any]) {
        let margins = numbers(measured["margins"])
        let layer = grid.layer
        layer.frame = rect(measured["pagerFrame"])
        (grid.leftMargin, grid.rightMargin, grid.topMargin, grid.bottomMargin) = (margins[0], margins[1], margins[2], margins[3])
        grid.zoomFactor = CGFloat((measured["zoomFactor"] as! NSNumber).doubleValue)
        grid.layout()
    }

    func expectPages(_ grid: ECSBSpringboard, as measured: [String: Any], _ name: String, onlyFirstPage: Bool = false) throws {
        let layer = grid.layer
        #expect(layer.scrollLayer.frame == rect(measured["scrollFrame"]), "\(name)")
        var pages = try #require(grid.pager.pages as? [ECSBPage])
        let measuredPages = measured["pages"] as! [[String: Any]]
        if onlyFirstPage {
            pages = Array(pages.prefix(1))
        }
        #expect(pages.count == measuredPages.count, "\(name)")
        for (page, measuredPage) in zip(pages, measuredPages) {
            let gridLayer = try #require(page.layer as? ECSBGridLayer)
            #expect(gridLayer.frame == rect(measuredPage["frame"]), "\(name)")
            #expect(gridLayer.clipLayer.frame == rect(measuredPage["clipFrame"]), "\(name)")
            #expect(gridLayer.itemsLayer.frame == rect(measuredPage["itemsFrame"]), "\(name)")
            #expect(gridLayer.rowHeight == (measuredPage["rowHeight"] as! UInt), "\(name)")
            #expect(gridLayer.columnWidth == (measuredPage["columnWidth"] as! UInt), "\(name)")
            #expect(gridLayer.rowSpacing == 0 && gridLayer.columnSpacing == 0)
            let itemLayers = try #require(gridLayer.itemLayers as? [CALayer])
            let measuredItems = measuredPage["items"] as! [[Any]]
            // The test layout has its own item counts; the cells they share must match.
            for (itemLayer, item) in zip(itemLayers, measuredItems) {
                let v = item.prefix(4).map { CGFloat(($0 as! NSNumber).doubleValue) }
                #expect(itemLayer.position == CGPoint(x: v[0], y: v[1]), "\(name)")
                #expect(itemLayer.bounds.size == CGSize(width: v[2], height: v[3]), "\(name)")
                #expect(itemLayer.isHidden == (item[4] as! Bool), "\(name)")
            }
        }
    }

    @Test("页和格子的位置与原版相同")
    func pagesAndCells() async throws {
        let springboard = try await launch()
        let saved = DockState()
        defer { saved.restore() }
        dockBar.display = DisplayDescriptor(notchBounds: .null)
        for name in ["default", "start", "left", "right", "tile16"] {
            let measured = layout(name)
            layOut(springboard.springboard, as: measured)
            // The measured layout had one page, the test layout has two; the first pages hold the
            // same 31 items.
            try expectPages(springboard.springboard, as: measured, name, onlyFirstPage: true)
            let pages = try #require(springboard.springboard.pager.pages as? [ECSBPage])
            let page = (measured["pages"] as! [[String: Any]])[0]
            // REF-GRID-007: the next page one pager layer width further.
            #expect(pages[1].layer?.frame == rect(page["frame"]).offsetBy(dx: springboard.springboard.layer.bounds.width, dy: 0),
                    "\(name)")
        }
    }

    @Test("从右到左时页和格子按原版镜像")
    func rightToLeft() async throws {
        let springboard = try await launch()
        let saved = DockState()
        defer { saved.restore() }
        dockBar.display = DisplayDescriptor(notchBounds: .null)
        let grid = ECSBSpringboard(handler: springboard, numberOfRowsPerPage: springboardRows,
                                   numberOfColumnsPerPage: springboardColumns, scaleFactor: 1, layoutRTL: true)
        grid.invalidate()
        let measured = layout("rtl")
        layOut(grid, as: measured)
        try expectPages(grid, as: measured, "rtl")
        #expect(grid.layer.scrollLayer.bounds.origin == CGPoint(x: numbers(measured["scrollOrigin"])[0], y: 0))
    }

    @Test("4 行 6 列时页和格子的位置与原版相同")
    func fourBySix() async throws {
        let springboard = try await launch()
        let saved = DockState()
        defer { saved.restore() }
        dockBar.display = DisplayDescriptor(notchBounds: .null)
        let grid = ECSBSpringboard(handler: springboard, numberOfRowsPerPage: 4, numberOfColumnsPerPage: 6, scaleFactor: 1,
                                   layoutRTL: false)
        grid.invalidate()
        let measured = layout("rows4cols6")
        layOut(grid, as: measured)
        try expectPages(grid, as: measured, "rows4cols6")
    }

    // MARK: - The controller's layout (REF-GRID-004)

    @Test("主网格按 Dock 的厚度和方向留出位置，边距和图标尺寸按 REF-GRID-004、006")
    func controllerLayout() async throws {
        let springboard = try await launch()
        // The Dock the tests run with (REF-DEV-019).
        do {
            let name = "this Dock"
            springboard.layout()
            // REF-GRID-004, on the display the tests run on.
            let bounds = springboard.layer.bounds
            let thickness = CGFloat((dockBar.tileSize + dockBar.distanceTop + dockBar.distanceBottom).rounded(.up))
            let orientation = dockBar.barOrientation
            let y: CGFloat = orientation == 0 ? thickness + 30 : 30
            let frame = CGRect(x: 0, y: y, width: bounds.width, height: bounds.height - y)
            #expect(springboard.springboard.layer.frame == frame, "\(name)")
            let width = orientation == 0 ? bounds.width : bounds.width - thickness
            let unit = (width / CGFloat(springboardColumns * 2 + 1)).rounded(.down)
            let room = (frame.height - CGFloat(springboardRows) * (unit + 40)).rounded(.down)
            let side = max((unit * 0.5).rounded(.down), 90)
            let top = max((room * 0.15).rounded(.down), 35)
            let bottom = max((room * 0.25).rounded(.down), 35)
            let grid = springboard.springboard!
            #expect([grid.leftMargin, grid.rightMargin, grid.topMargin, grid.bottomMargin] ==
                        [orientation == 1 ? side + thickness : side, orientation == 2 ? side + thickness : side, top, bottom],
                    "\(name)")
            var icon: UInt = 0
            var mini: UInt = 0
            ECSBSpringboard.calculateIconSize(&icon, miniIconSize: &mini, forBounds: frame,
                                              andScaleFactor: Float(Springboard.scaleFactor(of: springboard.display())),
                                              usingLeftMargin: side, rightMargin: side, topMargin: top, bottomMargin: bottom,
                                              zoomStyle: grid.layer.zoomStyle, zoomFactor: springboard.getZoomFactorFromPrefs(),
                                              withNumberOfRows: springboardRows, andColumns: springboardColumns)
            #expect([springboard.iconSize, springboard.miniIconSize] == [min(icon, 512), min(mini, 128)], "\(name)")
        }
    }

    @Test("在参考环境的显示器上，算出的图标尺寸与原版相同")
    func referenceIconSizes() {
        for name in ["default", "left", "tile16", "rows4cols6"] {
            let measured = layout(name)
            let margins = numbers(measured["margins"])
            let dock = measured["dock"] as! [String: Any]
            let orientation = dock["barOrientation"] as! Int
            let thickness = CGFloat(((dock["tileSize"] as! NSNumber).floatValue + (dock["distanceTop"] as! NSNumber).floatValue
                                         + (dock["distanceBottom"] as! NSNumber).floatValue).rounded(.up))
            let pages = measured["pages"] as! [[String: Any]]
            // The side margin without the Dock's thickness (REF-GRID-006).
            let side = orientation == 1 ? margins[0] - thickness : margins[0]
            var icon: UInt = 0
            var mini: UInt = 0
            ECSBSpringboard.calculateIconSize(&icon, miniIconSize: &mini, forBounds: rect(measured["pagerFrame"]),
                                              andScaleFactor: 1, usingLeftMargin: side, rightMargin: side,
                                              topMargin: margins[2], bottomMargin: margins[3],
                                              zoomStyle: measured["zoomStyle"] as! Int,
                                              zoomFactor: CGFloat((measured["zoomFactorFromPrefs"] as! NSNumber).doubleValue),
                                              withNumberOfRows: pages[0]["rows"] as! UInt,
                                              andColumns: pages[0]["columns"] as! UInt)
            #expect(icon == measured["iconSize"] as! UInt && mini == measured["miniIconSize"] as! UInt, "\(name)")
        }
    }

    // MARK: - The Dock (REF-DEV-019)

    @Test("没有矩形时按偏好的尺寸：瓦片大小加两倍内边距，距离与原版 Dock 的表相同")
    func dockGeometryFromPreference() {
        // REF-DEV-019: the original Dock's tile size and distances measured on macOS 15.6.1 for
        // preference sizes at which the bar did not shrink.
        let measured: [(size: Float, tileSize: Float, top: Float, bottom: Float)] = [
            (16, 18, 1, 7), (24, 26, 2, 7), (32, 34, 2, 7), (40, 42, 2, 7), (48, 52, 1, 10),
        ]
        for (size, tileSize, top, bottom) in measured {
            let geometry = DockBar.barGeometry(preferenceSize: size)
            #expect(geometry == (tileSize, top, bottom), "\(size)")
        }
    }

    @Test("Dock 的厚度从矩形换算，拆分与原版 Dock 的表相同")
    func dockThickness() {
        // REF-DEV-019: rectangles measured on macOS 15.6.1 and the original's tile size and distances.
        let measured: [(rect: Float, tileSize: Float, top: Float, bottom: Float)] = [
            (32, 18, 1, 7), (41, 26, 2, 7), (49, 34, 2, 7), (57, 42, 2, 7), (69, 52, 1, 10), (52, 36.602314, 2, 7),
            (77, 59.768337, 1, 10),
        ]
        for (rect, tileSize, top, bottom) in measured {
            let geometry = DockBar.barGeometry(rectThickness: rect)
            #expect(geometry.distanceTop == top && geometry.distanceBottom == bottom, "\(rect)")
            #expect((geometry.tileSize + geometry.distanceTop + geometry.distanceBottom).rounded(.up)
                        == (tileSize + top + bottom).rounded(.up), "\(rect)")
            if tileSize.rounded() == tileSize {
                #expect(geometry.tileSize == tileSize, "\(rect)")
            }
        }
        // Hidden automatically.
        #expect(DockBar.barGeometry(rectThickness: 0) == (0, 0, 0))
        var rect = CGRect.zero
        var reason: Int32 = 0
        var orientation: Int32 = 0
        SLSGetDockRectWithOrientation(CGSMainConnectionID(), &rect, &reason, &orientation)
        let thickness = dockBar.barOrientation == 0 ? rect.height : rect.width
        #expect(CGFloat(dockBar.tileSize + dockBar.distanceTop + dockBar.distanceBottom) == max(thickness - 6, 0))
    }

    // MARK: - Writing direction (REF-GRID-009)

    @Test("从右到左按原版的偏好和顺序判断")
    func writingDirection() {
        let domain = "io.github.wljf817.LaunchPad.tests.writing-direction" as CFString
        func set(_ key: String, _ value: Bool?) {
            CFPreferencesSetValue(key as CFString, value as CFPropertyList?, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        defer {
            for key in ["AppleTextDirection", "NSForceRightToLeftWritingDirection", "NSForceLeftToRightWritingDirection"] {
                set(key, nil)
            }
            CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        let system = SLSGetSystemUIHasRTLDirectionLegacy()
        let cases: [(Bool?, Bool?, Bool?, Bool)] = [
            (nil, nil, nil, system),
            (true, true, nil, true),
            (true, true, true, true),
            (true, nil, true, false),
            (true, nil, nil, system),
            (false, true, nil, system),
            (nil, true, nil, system),
        ]
        for (direction, right, left, expected) in cases {
            set("AppleTextDirection", direction)
            set("NSForceRightToLeftWritingDirection", right)
            set("NSForceLeftToRightWritingDirection", left)
            #expect(writingDirectionIsRightToLeft(domain: domain) == expected, "\(String(describing: direction)) \(String(describing: right)) \(String(describing: left))")
        }
    }

    // MARK: -

    func launch() async throws -> LPSpringboard {
        let startup = StartupTests()
        await startup.makeDatabase()
        let springboard = try await startup.launch(injecting: StartupTests.goldenApps())
        return springboard
    }
}

/// The shared Dock bar's display, restored after a test that replaces it.
@MainActor
struct DockState {
    let display = dockBar.display

    func restore() {
        dockBar.display = display
    }
}

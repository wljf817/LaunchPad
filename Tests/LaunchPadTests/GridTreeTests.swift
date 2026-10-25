import CoreText
import Foundation
import LaunchPadPrivate
import QuartzCore
import Testing
@testable import LaunchPad

/// The grid's component and layer tree (REF-ARCH-007, REF-GRID-003) and the loading indicator
/// (REF-GRID-001, REF-GRID-002), on the golden layout of REF-LAYOUT-008: two pages, the first with
/// 29 apps and two folders, as in the reference VM's dump.
@MainActor
struct GridTreeTests {
    let startup = StartupTests()

    func launchGolden() async throws -> LPSpringboard {
        await startup.makeDatabase()
        return try await startup.launch(injecting: StartupTests.goldenApps())
    }

    @Test("主网格的 layer 树与原版不开文件夹时的结构相同")
    func layerTree() async throws {
        let springboard = try await launchGolden()
        let grid = springboard.springboard!
        let pagerLayer = grid.layer
        #expect(springboard.layer.sublayers?.map(ObjectIdentifier.init) ==
                    [ObjectIdentifier(springboard.desktopContainerLayer), ObjectIdentifier(pagerLayer)])
        #expect(pagerLayer.sublayers?.map(ObjectIdentifier.init) ==
                    [ObjectIdentifier(pagerLayer.scrollLayer), ObjectIdentifier(pagerLayer.controlLayer)])
        // REF-PAGING-003: one dot per page, each with its dot layer.
        #expect(pagerLayer.controlLayer.sublayers?.map(ObjectIdentifier.init) ==
                    pagerLayer.controlLayer.indicatorLayers.map { ObjectIdentifier($0 as AnyObject) })
        #expect(pagerLayer.controlLayer.indicatorLayers.count == 2)
        #expect((pagerLayer.controlLayer.indicatorLayers as! [CALayer]).allSatisfy { $0.sublayers?.count == 1 })
        #expect(!pagerLayer.masksToBounds && !pagerLayer.scrollLayer.masksToBounds)
        #expect(!pagerLayer.isHidden)

        let pageItems = try #require(grid.item.items as? [ECSBPageItem])
        #expect(pageItems.count == 2)
        #expect(pageItems.first?.items?.count == 31)
        let pages = try #require(grid.pager.pages as? [ECSBPage])
        #expect(pages.map(ObjectIdentifier.init) == pageItems.map { ObjectIdentifier($0.page!) })
        #expect(pagerLayer.scrollLayer.sublayers?.map(ObjectIdentifier.init) == pages.map { ObjectIdentifier($0.layer!) })
        for (index, page) in pages.enumerated() {
            #expect(page.index == UInt(index))
            #expect(page.pager === grid.pager)
            let gridLayer = try #require(page.layer as? ECSBGridLayer)
            #expect(gridLayer.layerSource === page)
            #expect(gridLayer.sublayers?.map(ObjectIdentifier.init) == [ObjectIdentifier(gridLayer.clipLayer)])
            #expect(gridLayer.clipLayer.sublayers?.map(ObjectIdentifier.init) == [ObjectIdentifier(gridLayer.itemsLayer)])
            #expect(!gridLayer.clipLayer.masksToBounds)
            let items = try #require(page.item.items as? [ECSBItem])
            let itemLayers = try #require(gridLayer.itemLayers as? [ECSBItemLayer])
            #expect(itemLayers.count == items.count)
            // REF-GRID-003: the first item is the last sublayer.
            #expect(gridLayer.itemsLayer.sublayers?.map(ObjectIdentifier.init) == itemLayers.reversed().map(ObjectIdentifier.init))
            for (item, itemLayer) in zip(items, itemLayers) {
                #expect(item.itemLayer === itemLayer)
                #expect(itemLayer.item === item)
                #expect(type(of: itemLayer) == (item is ECSBGroupItem ? ECSBGroupItemLayer.self : ECSBItemLayer.self))
                #expect(itemLayer.sublayers?.map(ObjectIdentifier.init) == [ObjectIdentifier(itemLayer.transformLayer)])
                #expect(itemLayer.transformLayer.sublayers?.map(ObjectIdentifier.init) == [ObjectIdentifier(itemLayer.jitterLayer)])
                #expect(!itemLayer.jitterLayer.allowsGroupBlending)
            }
        }
        // The two folders are the last items of the first page (REF-LAYOUT-008).
        let firstItems = try #require(pageItems.first?.items as? [ECSBItem])
        #expect(firstItems.suffix(2).allSatisfy { $0 is ECSBGroupItem })
        #expect(firstItems.dropLast(2).allSatisfy { !($0 is ECSBGroupItem) })
    }

    @Test("隐藏页和旧版本根里的应用不在主网格里")
    func hiddenItems() async throws {
        let springboard = try await launchGolden()
        let manager = try #require(springboard.appManager)
        let hidden = makeTestApp("Hidden", bundleID: "test.hidden")
        let old = makeTestApp("Old", bundleID: "test.old")
        springboard.rootPage?.addItemToPurgatory(hidden)
        manager.lpversroot?.addItemToPurgatory(old)
        springboard.springboard.invalidate()
        expectItemTree(springboard)
        var clients: [AnyObject] = []
        func collect(_ item: ECSBItem) {
            if let client = item.clientItem {
                clients.append(client)
            }
            for case let child as ECSBItem in item.items ?? [] {
                collect(child)
            }
        }
        collect(springboard.springboard.item)
        #expect(!clients.contains { $0 === hidden || $0 === old })
    }

    @Test("启动时显示「加载中」，处理完首次扫描时去掉")
    func loadingIndicator() async throws {
        await startup.makeDatabase()
        let manager = try #require(LPAppManager(atPath: startup.databasePath, readOnly: false))
        LPAppManager.shared = manager
        let springboard = LPSpringboard()
        springboard.activate()

        let container = try #require(springboard.loadingContainerLayer)
        let text = try #require(springboard.loadingLayer)
        #expect(springboard.layer.sublayers?.last === container)
        #expect(container.sublayers?.map(ObjectIdentifier.init) == [ObjectIdentifier(text)])
        #expect(!container.allowsGroupBlending)
        #expect(springboard.springboard.layer.isHidden)
        // REF-GRID-002
        #expect(text.string as? String == "正在载入应用程序…")
        let font = try #require(text.font.map { $0 as! CTFont })
        #expect(CTFontCopyPostScriptName(font) as String == ".SFNS-Light")
        #expect(CTFontGetSize(font) == 60)
        #expect(text.fontSize == 60)
        let gray: [CGFloat] = [52.0 / 255.0, 1]
        #expect(text.foregroundColor?.components == gray)
        #expect(text.compositingFilter as? String == "plusL")
        let shadow: [CGFloat] = [0, 0.2]
        #expect((text.textShadowColor as! CGColor?)?.components == shadow)
        #expect(text.textShadowOffset == CGSize(width: 0, height: -1))
        #expect(text.textShadowBlur == 2)
        #expect(!text.textShadowHidden)
        #expect(text.alignmentMode == .left)
        #expect(text.contentsScale == Springboard.scaleFactor(of: springboard.display()))
        // Layout is deferred until -start (REF-GRID-001).
        #expect(container.frame == .zero)

        springboard.start()
        let bounds = springboard.layer.bounds
        #expect(bounds.size == CGDisplayBounds(springboard.display()).size)
        let size = text.preferredFrameSize()
        #expect(size.height == 71)
        #expect(container.frame == CGRect(x: CGFloat(Int32(bounds.width / 2 - size.width / 2)),
                                          y: (bounds.height / 2 - size.height / 2).rounded(.up),
                                          width: size.width.rounded(.up), height: size.height.rounded(.up)))
        #expect(text.frame == container.bounds)

        try await waitUntilStarted(springboard)
        let deadline = Date().addingTimeInterval(5)
        while springboard.loadingLayer != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(springboard.loadingLayer == nil)
        #expect(springboard.loadingContainerLayer == nil)
        #expect(container.superlayer == nil && text.superlayer == nil)
        #expect(!springboard.springboard.layer.isHidden)
        #expect(springboard.layer.sublayers?.contains(container) == false)
    }

    @Test("壁纸变化的通知：显示器和空间对得上才重取背景")
    func desktopPictureChanged() async throws {
        await startup.makeDatabase()
        LPAppManager.shared = try #require(LPAppManager(atPath: startup.databasePath, readOnly: false))
        let springboard = LPSpringboard()
        springboard.activate()
        // Closed: the background is only marked stale when it is asked to update while it exists.
        springboard.desktopLayer = CALayer()
        let display = springboard.display()
        let space = spaces.currentSpace(forDisplay: display)?.uuid
        NotificationCenter.default.post(name: NSNotification.Name("desktoppicturechanged"), object: gDesktopPictureManager,
                                        userInfo: ["did": NSNumber(value: display &+ 1), "uuid": space ?? ""])
        #expect(!springboard.desktopStale)
        NotificationCenter.default.post(name: NSNotification.Name("desktoppicturechanged"), object: gDesktopPictureManager,
                                        userInfo: ["did": NSNumber(value: display), "uuid": space ?? ""])
        #expect(springboard.desktopStale == (space != nil))
    }
}

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

    func solidImage(_ size: Int) -> CGImage? {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context?.makeImage()
    }
}

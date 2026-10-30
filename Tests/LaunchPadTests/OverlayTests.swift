import AppKit
import LaunchPadPrivate
import QuartzCore
import Testing
@testable import LaunchPad

// The parts of the overlay that run without showing a window, taking the keyboard focus or changing
// the Dock's settings. Opening and closing themselves are checked in the comparison VM.

@MainActor
@Suite struct WindowTests {
    @Test("全局坐标换成 AppKit 坐标")
    func appKitRect() {
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let rect = WALayerKitWindow.appKitRect(CGRect(x: 10, y: 20, width: 300, height: 40))
        #expect(rect == NSRect(x: 10, y: mainHeight - 60, width: 300, height: 40))
    }

    @Test("窄条在上，主窗口是其余部分")
    func windowFrames() {
        Self.waitForMenuBar()
        let frame = CGDisplayBounds(CGMainDisplayID())
        let (main, strip) = WALayerKitWindow.windowFrames(for: frame)
        #expect(strip.minY == frame.minY)
        #expect(main.minY == strip.maxY)
        #expect(main.maxY == frame.maxY)
        #expect(main.width == frame.width && strip.width == frame.width)
        #expect(strip.height == WALayerKitWindow.menuBarHeight(in: frame))
    }

    @Test("副本跟着原树的结构和属性")
    func copyFollowsTree() throws {
        let window = makeWindow()
        let child = CALayer()
        let band = try stripBand(window)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        child.frame = CGRect(x: band.minX + 1, y: band.minY, width: 30, height: 40)
        child.opacity = 0.25
        child.contents = makeImage()
        child.filters = [CAFilter(type: kCAFilterGaussianBlur)]
        window.layer.addSublayer(child)
        CATransaction.commit()
        // The window's creation left an implicit transaction open; the commit handlers run when it commits.
        CATransaction.flush()

        let rootCopy = try #require(window.stripLayer.sublayers?.first)
        let childCopy = try #require(rootCopy.sublayers?.first)
        #expect(rootCopy.sublayers?.count == 1)
        #expect(childCopy !== child)
        #expect(childCopy.frame == child.frame)
        #expect(childCopy.opacity == 0.25)
        #expect((childCopy.contents as AnyObject?) === (child.contents as AnyObject?))
        #expect(childCopy.filters?.count == 1)

        CATransaction.begin()
        child.removeFromSuperlayer()
        CATransaction.commit()
        // The window's creation left an implicit transaction open; the commit handlers run when it commits.
        CATransaction.flush()
        #expect(rootCopy.sublayers == nil)
    }

    @Test("不透明的 layer 的副本有不透明的背景色，其余副本照原树")
    func opaqueLayerCopyHasBackground() throws {
        let window = makeWindow()
        let opaque = CALayer()
        let other = CALayer()
        window.opaqueLayer = opaque
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.layer.addSublayer(opaque)
        window.layer.addSublayer(other)
        CATransaction.commit()
        // The window's creation left an implicit transaction open; the commit handlers run when it commits.
        CATransaction.flush()

        let copies = try #require(window.stripLayer.sublayers?.first?.sublayers)
        #expect(copies.count == 2)
        #expect(copies[0].backgroundColor?.alpha == 1)
        #expect(opaque.backgroundColor == nil)
        #expect(copies[1].backgroundColor == nil)
    }

    @Test("副本的动画与原树的同键、同时长、同曲线，同一次提交开始")
    func copyTakesAnimations() throws {
        let window = makeWindow()
        let child = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.layer.addSublayer(child)
        CATransaction.commit()
        // The window's creation left an implicit transaction open; the commit handlers run when it commits.
        CATransaction.flush()

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
        child.add(CABasicAnimation(keyPath: "opacity"), forKey: "opacity")
        child.opacity = 0.5
        CATransaction.commit()
        // The window's creation left an implicit transaction open; the commit handlers run when it commits.
        CATransaction.flush()

        let childCopy = try #require(window.stripLayer.sublayers?.first?.sublayers?.first)
        let original = try #require(child.animation(forKey: "opacity"))
        let copied = try #require(childCopy.animation(forKey: "opacity"))
        #expect(copied.duration == original.duration)
        #expect(copied.timingFunction == original.timingFunction)
        #expect(copied.beginTime == original.beginTime)
        #expect(childCopy.opacity == 0.5)
    }

    @Test("副本的根与原树在显示器上的位置对齐")
    func copyIsOffsetToTheStrip() throws {
        let window = makeWindow()
        let rootCopy = try #require(window.stripLayer.sublayers?.first)
        let main = try #require(window.mainWindow?.frame)
        let strip = try #require(window.stripWindow?.frame)
        #expect(rootCopy.position.x == window.layer.position.x + main.minX - strip.minX)
        #expect(rootCopy.position.y == window.layer.position.y + main.minY - strip.minY)
    }

    @Test("帧没变但窗口被移走时，放回原处，副本跟着对齐")
    func setFrameRestoresMovedWindows() throws {
        let window = makeWindow()
        let frame = CGDisplayBounds(CGMainDisplayID())
        let (main, strip) = WALayerKitWindow.windowFrames(for: frame)
        let stripWindow = try #require(window.stripWindow)
        stripWindow.setFrameOrigin(NSPoint(x: stripWindow.frame.minX, y: stripWindow.frame.minY - 300))

        window.setFrame(frame)
        CATransaction.flush()

        #expect(stripWindow.frame == WALayerKitWindow.appKitRect(strip))
        #expect(window.mainWindow?.frame == WALayerKitWindow.appKitRect(main))
        let rootCopy = try #require(window.stripLayer.sublayers?.first)
        let mainFrame = try #require(window.mainWindow?.frame)
        #expect(rootCopy.position.y == window.layer.position.y + mainFrame.minY - stripWindow.frame.minY)
    }

    @Test("帧没变但窗口按 0 高的窄条摆着时，按菜单栏现在的高度重摆")
    func setFrameFollowsMenuBarHeight() throws {
        let window = makeWindow()
        let frame = CGDisplayBounds(CGMainDisplayID())
        let (main, strip) = WALayerKitWindow.windowFrames(for: frame)
        try #require(strip.height > 0)
        // As at login, before the menu bar's height was known.
        let stripWindow = try #require(window.stripWindow)
        let mainWindow = try #require(window.mainWindow)
        stripWindow.setFrame(WALayerKitWindow.appKitRect(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 0)),
                             display: false)
        mainWindow.setFrame(WALayerKitWindow.appKitRect(frame), display: false)

        window.setFrame(frame)
        CATransaction.flush()

        #expect(stripWindow.frame == WALayerKitWindow.appKitRect(strip))
        #expect(mainWindow.frame == WALayerKitWindow.appKitRect(main))
    }

    @Test("只复制能到顶条那一段的 layer；缩放动画能把它带进去时也复制")
    func copyKeepsOnlyTheStripsBand() throws {
        let window = makeWindow()
        let band = try stripBand(window)
        let inside = CALayer()
        let below = CALayer()
        let zoomed = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inside.frame = CGRect(x: band.minX, y: band.minY, width: 10, height: band.height)
        // Twice the band's height away from it, on the side away from the tree's edge.
        let away: CGFloat = band.minY > window.layer.bounds.midY ? -1 : 1
        let gap = band.height * 2
        below.frame = CGRect(x: band.minX, y: away > 0 ? band.maxY + gap : band.minY - gap - 10, width: 10, height: 10)
        zoomed.frame = window.layer.bounds
        window.layer.addSublayer(inside)
        window.layer.addSublayer(below)
        CATransaction.commit()
        CATransaction.flush()
        var copies = try #require(window.stripLayer.sublayers?.first?.sublayers)
        #expect(copies.count == 1)
        #expect(copies.first?.frame == inside.frame)

        // A layer that only reaches the band at the start of its zoom (REF-OVERLAY-001) is copied while
        // the zoom runs.
        let content = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame = below.frame
        zoomed.addSublayer(content)
        window.layer.addSublayer(zoomed)
        zoomed.add(zoom(from: scale(taking: content.frame, into: band, about: zoomed.position)), forKey: "transform")
        CATransaction.commit()
        CATransaction.flush()
        copies = try #require(window.stripLayer.sublayers?.first?.sublayers)
        #expect(copies.count == 2)
        #expect(copies.last?.sublayers?.first?.frame == content.frame)
    }

    @Test("缩放中到不了顶条的 layer 不复制，按整棵树的尺寸放宽时会到的也一样")
    func copyLeavesOutWhatAZoomKeepsAway() throws {
        let window = makeWindow()
        let band = try stripBand(window)
        let away: CGFloat = band.minY > window.layer.bounds.midY ? -1 : 1
        let gap = band.height * 2
        let zoomed = CALayer()
        let content = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        zoomed.frame = window.layer.bounds
        content.frame = CGRect(x: band.minX, y: away > 0 ? band.maxY + gap : band.minY - gap - 10, width: 10, height: 10)
        zoomed.addSublayer(content)
        window.layer.addSublayer(zoomed)
        // Half way to the band: the zoom moves the content's edge by half the gap.
        let half = 1 + (scale(taking: content.frame, into: band, about: zoomed.position) - 1) / 2
        // Before REF-DEV-003's exact rule, a layer under a zoom was widened by the zoom's change of scale
        // times the tree's size, which took this one in.
        let size = max(window.layer.bounds.width, window.layer.bounds.height)
        try #require((half - 1) * size > gap)
        zoomed.add(zoom(from: half), forKey: "transform")
        CATransaction.commit()
        CATransaction.flush()
        var zoomedCopy = try #require(window.stripLayer.sublayers?.first?.sublayers?.first)
        #expect(zoomedCopy.sublayers == nil)

        // The close: the model is the larger scale and the zoom only shrinks from it (REF-OVERLAY-004). A
        // layer whose model rectangle stops a point short of the band stays out, although the earlier
        // rule, widening it by the change of scale times the tree's size, would take it in.
        let large = scale(taking: content.frame, into: band, about: zoomed.position)
        let short = 1 + (large - 1) * (1 - 2 / gap)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        zoomed.removeAllAnimations()
        zoomed.transform = CATransform3DMakeScale(short, short, 1)
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        shrink.duration = 10
        zoomed.add(shrink, forKey: "transform")
        CATransaction.commit()
        CATransaction.flush()
        let modelRect = content.convert(content.bounds, to: window.layer)
        try #require(!modelRect.intersects(band))
        let earlierReach = (1 - 1 / short) * size
        try #require(modelRect.insetBy(dx: -earlierReach, dy: -earlierReach).intersects(band))
        zoomedCopy = try #require(window.stripLayer.sublayers?.first?.sublayers?.first)
        #expect(zoomedCopy.sublayers == nil)
    }

    @Test("两层缩放合起来才把 layer 带到顶条时也复制")
    func copyCountsNestedZooms() throws {
        let window = makeWindow()
        let band = try stripBand(window)
        let away: CGFloat = band.minY > window.layer.bounds.midY ? -1 : 1
        let gap = band.height * 2
        let outer = CALayer()
        let inner = CALayer()
        let content = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outer.frame = window.layer.bounds
        inner.frame = outer.bounds
        content.frame = CGRect(x: band.minX, y: away > 0 ? band.maxY + gap : band.minY - gap - 10, width: 10, height: 10)
        inner.addSublayer(content)
        outer.addSublayer(inner)
        window.layer.addSublayer(outer)
        // Each zoom alone moves the content's edge only part of the way; both together take it one point
        // into the band.
        let each = scale(taking: content.frame, into: band, about: outer.position).squareRoot()
        outer.add(zoom(from: each), forKey: "transform")
        CATransaction.commit()
        CATransaction.flush()
        var innerCopy = try #require(window.stripLayer.sublayers?.first?.sublayers?.first?.sublayers?.first)
        #expect(innerCopy.sublayers == nil)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inner.add(zoom(from: each), forKey: "transform")
        // Any change of a copied layer schedules the sync; adding an animation alone does not.
        inner.opacity = 0.5
        CATransaction.commit()
        CATransaction.flush()
        innerCopy = try #require(window.stripLayer.sublayers?.first?.sublayers?.first?.sublayers?.first)
        #expect(innerCopy.sublayers?.first?.frame == content.frame)
    }

    /// The scale about `center` that takes the edge of `rect` facing `band` one point into the band, for a
    /// rectangle between `center` and the band.
    func scale(taking rect: CGRect, into band: CGRect, about center: CGPoint) -> CGFloat {
        let (edge, target) = rect.maxY <= band.minY ? (rect.maxY, band.minY + 1) : (rect.minY, band.maxY - 1)
        return (target - center.y) / (edge - center.y)
    }

    /// A zoom from `scale` to the model transform, as the open's (REF-OVERLAY-001), long enough to run
    /// through the test.
    func zoom(from scale: CGFloat) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: CATransform3DMakeScale(scale, scale, 1))
        animation.duration = 10
        return animation
    }

    /// The strip's area in the tree's coordinates.
    func stripBand(_ window: WALayerKitWindow) throws -> CGRect {
        let rootCopy = try #require(window.stripLayer.sublayers?.first)
        let band = rootCopy.convert(window.stripLayer.bounds, from: window.stripLayer)
        try #require(!band.isEmpty)
        return band
    }

    /// These tests read the system's menu bar. While the main display switches spaces or an app enters
    /// or leaves full screen, the menu bar windows slide sideways and for a moment none is at the
    /// display's edge (whether or not the window server reports a space animation); waits until one is,
    /// at most 10 s.
    static func waitForMenuBar() {
        let frame = CGDisplayBounds(CGMainDisplayID())
        let deadline = Date().addingTimeInterval(10)
        while WALayerKitWindow.menuBarHeight(in: frame) == 0, Date() < deadline {
            usleep(20_000)
        }
    }

    func makeWindow() -> WALayerKitWindow {
        Self.waitForMenuBar()
        let display = CGMainDisplayID()
        let window = WALayerKitWindow(frame: CGDisplayBounds(display), connection: UInt32(bitPattern: CGSMainConnectionID()),
                                      display: display, tags: 0x400, level: 20)
        CATransaction.flush()
        return window
    }

    func makeImage() -> CGImage {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        return context.makeImage()!
    }
}

@MainActor
@Suite(.serialized) struct SpringboardTests {
    @Test("背景容器在覆盖层容器的最底层，三个滤镜的参数")
    func layerTreeAndFilters() throws {
        let springboard = Springboard()
        #expect(springboard.layer.sublayers?.first === springboard.desktopContainerLayer)
        #expect(springboard.layer.delegate === springboard)
        let filters = springboard.desktopFilters
        #expect(filters.count == 3)
        // REF-OVERLAY-005
        #expect((filters[0].value(forKey: "inputRadius") as? NSNumber)?.intValue == 30)
        #expect((filters[0].value(forKey: "inputHardEdges") as? NSNumber)?.boolValue == true)
        #expect((filters[1].value(forKey: "inputAmount") as? NSNumber)?.doubleValue == 1.8)
        let matrix = try #require(filters[2].value(forKey: "inputColorMatrix") as? NSValue).caColorMatrixValue
        #expect([matrix.m11, matrix.m22, matrix.m33, matrix.m44] == [0.55, 0.55, 0.55, 1])
        #expect([matrix.m15, matrix.m25, matrix.m35, matrix.m45] == [0.05292, 0.05292, 0.05292, 0])
        #expect([matrix.m12, matrix.m13, matrix.m14, matrix.m21, matrix.m23, matrix.m24,
                 matrix.m31, matrix.m32, matrix.m34, matrix.m41, matrix.m42, matrix.m43].allSatisfy { $0 == 0 })
    }

    @Test("时长：慢放、偏好键、默认值")
    func animationDuration() {
        let key = "springboard-show-duration"
        let defaults = UserDefaults.standard
        defer { defaults.removeObject(forKey: key) }
        // REF-OVERLAY-008
        #expect(Springboard.animationDuration(slow: true, key: key) == 5)
        defaults.removeObject(forKey: key)
        #expect(Springboard.animationDuration(slow: false, key: key) == CATransaction.animationDuration())
        defaults.set(1.5, forKey: key)
        #expect(Springboard.animationDuration(slow: false, key: key) == 1.5)
        defaults.set(0.3, forKey: key)
        #expect(Springboard.animationDuration(slow: false, key: key) == CFTimeInterval(Float(0.3)))
        defaults.set(0, forKey: key)
        #expect(Springboard.animationDuration(slow: false, key: key) == 0)
        defaults.set(-1, forKey: key)
        #expect(Springboard.animationDuration(slow: false, key: key) == -1)
        defaults.set("1.5", forKey: key)
        #expect(Springboard.animationDuration(slow: false, key: key) == CATransaction.animationDuration())
        defaults.set(2, forKey: key)
        #expect(Springboard.animationDuration(slow: true, key: key) == 5)
    }

    @Test("关着时不换背景")
    func updateDesktopImagesWhileClosed() {
        let springboard = Springboard()
        springboard.updateDesktopImages()
        #expect(springboard.desktopLayer == nil)
        #expect(!springboard.desktopStale)
        #expect(springboard.desktopLastUUID == nil)
    }

    @Test("有背景但不可见时标为过期")
    func updateDesktopImagesWhileNotVisible() {
        let springboard = Springboard()
        let background = CALayer()
        springboard.desktopLayer = background
        springboard.updateDesktopImages()
        #expect(springboard.desktopLayer === background)
        #expect(springboard.desktopStale)
    }

    @Test("可见时换成新背景，记下空间")
    func updateDesktopImagesWhileVisible() {
        let springboard = Springboard()
        let background = CALayer()
        springboard.desktopContainerLayer.addSublayer(background)
        springboard.desktopLayer = background
        springboard.desktopStale = true
        springboard._visible = true
        springboard.updateDesktopImages()
        #expect(springboard.desktopLayer !== background)
        #expect(springboard.desktopLayer?.superlayer === springboard.desktopContainerLayer)
        #expect(!springboard.desktopStale)
        #expect(springboard.desktopLastUUID == spaces.currentSpace(forDisplay: springboard.display())?.uuid)
    }
}

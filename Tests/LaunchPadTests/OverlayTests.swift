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

        // A layer that only reaches the band while its zoom runs (REF-OVERLAY-001) is copied too.
        let content = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame = below.frame
        zoomed.addSublayer(content)
        window.layer.addSublayer(zoomed)
        let size = max(window.layer.bounds.width, window.layer.bounds.height)
        let scale = 1 + (gap + 20) / size
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: CATransform3DMakeScale(scale, scale, 1))
        animation.duration = 10
        zoomed.add(animation, forKey: "transform")
        CATransaction.commit()
        CATransaction.flush()
        copies = try #require(window.stripLayer.sublayers?.first?.sublayers)
        #expect(copies.count == 2)
        #expect(copies.last?.sublayers?.first?.frame == content.frame)
    }

    /// The strip's area in the tree's coordinates.
    func stripBand(_ window: WALayerKitWindow) throws -> CGRect {
        let rootCopy = try #require(window.stripLayer.sublayers?.first)
        let band = rootCopy.convert(window.stripLayer.bounds, from: window.stripLayer)
        try #require(!band.isEmpty)
        return band
    }

    func makeWindow() -> WALayerKitWindow {
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

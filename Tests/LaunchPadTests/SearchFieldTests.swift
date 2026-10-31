import CoreText
import Foundation
import ImageIO
import QuartzCore
import Testing
@testable import LaunchPad

/// The search field's layers, layout and state (REF-SEARCH-001, REF-SEARCH-002, REF-SEARCH-005),
/// with the images of `testResources`.
@MainActor
struct SearchFieldTests {
    init() {
        launchPadBundle = testResources
    }

    /// A search field set up as the grid layer sets it up (REF-SEARCH-001): 250 × 25, `.SFNS-Light`
    /// 16, the placeholder `搜索`.
    func makeField(scaleFactor: Float = 1, layoutRTL: Bool = false) -> ECTextInputLayer {
        let field = ECTextInputLayer(cgSize: CGSize(width: 250, height: 25), type: 1, scaleFactor: scaleFactor, layoutRTL: layoutRTL,
                                     containerWindow: nil)
        field.font = CTFontCreateUIFontForLanguage(CTFontUIFontType(rawValue: 103)!, 16, nil)
        field.fontSize = 16
        field.placeholderString = "搜索"
        field.foregroundColor = CGColor(gray: 1, alpha: 1)
        return field
    }

    static let frame = CGRect(x: 0, y: 0, width: 250, height: 25)

    /// The decoded pixels of an image file of `testResources`.
    func filePixels(_ file: String) throws -> Data {
        let url = try #require(testResources.url(forResource: file, withExtension: nil))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try pixels(try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }

    func pixels(_ image: CGImage) throws -> Data {
        try #require(image.dataProvider?.data) as Data
    }

    func contentsImage(_ layer: CALayer?) throws -> CGImage {
        let contents = try #require(layer?.contents)
        return contents as! CGImage
    }

    // MARK: - Creation (REF-SEARCH-001)

    @Test("搜索类型的边距是高度，其他类型是 4")
    func margins() {
        let search = makeField()
        search.frame = Self.frame
        #expect(search._hostLayer.frame == CGRect(x: 25, y: 0, width: 200, height: 25))

        let plain = ECTextInputLayer(cgSize: CGSize(width: 250, height: 25), type: 0, scaleFactor: 1, layoutRTL: false, containerWindow: nil)
        plain.frame = Self.frame
        #expect(plain._hostLayer.frame == CGRect(x: 4, y: 0, width: 242, height: 25))
    }

    @Test("子 layer 依次是占位文字、放大镜、清除按钮、CALayerHost；其他类型只有 CALayerHost")
    func sublayers() throws {
        let field = makeField()
        let sublayers = try #require(field.sublayers)
        #expect(sublayers.map(ObjectIdentifier.init) == [field._placeholderLayer!, field._magnifyLayer!, field._cancelSearchLayer!, field._hostLayer!]
            .map(ObjectIdentifier.init))
        #expect(sublayers.map { NSStringFromClass(type(of: $0)) } == ["ECTextLayer", "CALayer", "CALayer", "CALayerHost"])

        let plain = ECTextInputLayer(cgSize: CGSize(width: 250, height: 25), type: 0, scaleFactor: 1, layoutRTL: false, containerWindow: nil)
        #expect(plain.sublayers?.map { NSStringFromClass(type(of: $0)) } == ["CALayerHost"])
        #expect(plain.contents == nil)
    }

    @Test("清除按钮隐藏、不透明度 0.3、事件交给搜索框；背景和图标的拉伸方式")
    func searchLayers() {
        let field = makeField()
        let cancel = field._cancelSearchLayer!
        #expect(cancel.isHidden)
        #expect(cancel.opacity == 0.3)
        #expect(cancel.eventDelegate === field)
        #expect(field.contentsCenter == CGRect(x: 0.5, y: 0, width: 0, height: 1))
        #expect(field._magnifyLayer!.contentsGravity == .resizeAspect)
        #expect(cancel.contentsGravity == .resizeAspect)
    }

    /// Records the image layers as `-_setupSearchLayers` leaves them.
    final class SetupRecordingField: ECTextInputLayer {
        var setupScales: [CGFloat] = []
        var setupContents: [Bool] = []

        override func _setupSearchLayers() {
            super._setupSearchLayers()
            let layers: [CALayer] = [self, _magnifyLayer!, _cancelSearchLayer!]
            setupScales = layers.map(\.contentsScale)
            setupContents = layers.map { $0.contents != nil }
        }
    }

    @Test("建图片层时缩放比是 0、没有图片，初始化结束后三张图片都装上")
    func imagesAfterSetup() throws {
        let field = SetupRecordingField(cgSize: CGSize(width: 250, height: 25), type: 1, scaleFactor: 1, layoutRTL: false, containerWindow: nil)
        #expect(field.setupScales == [0, 0, 0])
        #expect(field.setupContents == [false, false, false])
        #expect(field.contents != nil && field._magnifyLayer?.contents != nil && field._cancelSearchLayer?.contents != nil)
    }

    @Test("按缩放比装上图片，各 layer 的 contentsScale 是缩放比", arguments: [
        (Float(1), "", 11, 22, 12, 14),
        (Float(2), "@2x", 22, 44, 24, 28),
    ])
    func images(scaleFactor: Float, suffix: String, backgroundWidth: Int, backgroundHeight: Int, loupe: Int, close: Int) throws {
        let field = makeField(scaleFactor: scaleFactor)
        let background = try contentsImage(field)
        let magnifier = try contentsImage(field._magnifyLayer)
        let cancel = try contentsImage(field._cancelSearchLayer)
        #expect((background.width, background.height) == (backgroundWidth, backgroundHeight))
        #expect((magnifier.width, magnifier.height) == (loupe, loupe))
        #expect((cancel.width, cancel.height) == (close, close))
        #expect(try pixels(background) == filePixels("ectl_search_background\(suffix).png"))
        #expect(try pixels(magnifier) == filePixels("ectl_search_loupe\(suffix).png"))
        #expect(try pixels(cancel) == filePixels("ectl_search_close\(suffix).png"))
        let scales = [field, field._magnifyLayer!, field._cancelSearchLayer!, field._placeholderLayer!].map(\.contentsScale)
        #expect(scales == Array(repeating: CGFloat(scaleFactor), count: 4))
    }

    @Test("从右到左用另一张放大镜")
    func rightToLeftLoupe() throws {
        try #require(try filePixels("ectl_search_loupe.png") != filePixels("ectl_search_loupe_rtl.png"))
        let field = makeField(layoutRTL: true)
        #expect(try pixels(contentsImage(field._magnifyLayer)) == filePixels("ectl_search_loupe_rtl.png"))
    }

    @Test("改缩放比时重新取三张图片，四个 layer 的 contentsScale 跟着改")
    func changeScaleFactor() throws {
        let field = makeField(scaleFactor: 1)
        field.scaleFactor = 2
        #expect(try contentsImage(field).width == 22)
        #expect(try contentsImage(field._magnifyLayer).width == 24)
        #expect(try contentsImage(field._cancelSearchLayer).width == 28)
        let scales = [field, field._magnifyLayer!, field._cancelSearchLayer!, field._placeholderLayer!].map(\.contentsScale)
        #expect(scales == [2, 2, 2, 2])
    }

    @Test("占位文字的字体、字号、字符串和固定的灰色；前景色不改它")
    func placeholderLook() throws {
        let field = makeField()
        let placeholder = try #require(field._placeholderLayer)
        #expect(placeholder.font === field.font)
        #expect(placeholder.fontSize == 16)
        #expect(placeholder.string as? String == "搜索")
        #expect(placeholder.foregroundColor == CGColor(gray: 1, alpha: 0.36))
    }

    @Test("有字体时占位文字的高度按字体本身的字号量")
    func placeholderHeightFromFont() throws {
        let field = makeField()
        field.fontSize = 32
        let placeholder = try #require(field._placeholderLayer)
        try #require(placeholder.preferredFrameSize().height != 19)
        field.frame = Self.frame
        #expect(placeholder.frame.height == 19)
    }

    @Test("值不变时的设置什么也不做")
    func unchangedValues() throws {
        let field = makeField()
        field.frame = Self.frame
        let placeholder = try #require(field._placeholderLayer)
        let magnifier = try #require(field._magnifyLayer)

        let other = CTFontCreateUIFontForLanguage(CTFontUIFontType(rawValue: 103)!, 20, nil)
        placeholder.font = other
        placeholder.fontSize = 20
        placeholder.string = "x"
        field.font = field.font
        field.fontSize = 16
        field.placeholderString = field.placeholderString
        #expect(placeholder.font === other)
        #expect(placeholder.fontSize == 20)
        #expect(placeholder.string as? String == "x")

        field.contents = nil
        field.scaleFactor = 1
        #expect(field.contents == nil)

        let string: NSString = "a"
        field.stringValue = string
        placeholder.isHidden = false
        field.stringValue = string
        #expect(!placeholder.isHidden)

        magnifier.frame = .zero
        field.textFieldActive = false
        field.hasFocus = false
        #expect(magnifier.frame == .zero)

        field.opacity = 0.5
        field.fadeWhenNotActive = false
        #expect(field.opacity == 0.5)
    }

    @Test("按 pid 找不到搜索框时返回 nil")
    func layerForHelperPID() {
        withExtendedLifetime(makeField()) {
            #expect(ECTextInputLayer.layer(forHelperPID: getpid()) == nil)
        }
    }

    // MARK: - Layout (REF-SEARCH-002)

    @Test("250 × 25、占位文字 33 × 19 时子 layer 的 frame", arguments: [
        // active, right to left, placeholder x, magnifier x, cancel x
        (false, false, 120.5, 100.5, 230.0),
        (false, true, 96.5, 137.5, 6.0),
        (true, false, 27.0, 7.0, 230.0),
        (true, true, 190.0, 231.0, 6.0),
    ])
    func layout(active: Bool, layoutRTL: Bool, placeholderX: CGFloat, magnifierX: CGFloat, cancelX: CGFloat) throws {
        let field = makeField(layoutRTL: layoutRTL)
        try #require(field._placeholderLayer?.preferredFrameSize() == CGSize(width: 33, height: 19))
        field.textFieldActive = active
        field.frame = Self.frame
        #expect(field._placeholderLayer?.frame == CGRect(x: placeholderX, y: 4, width: 33, height: 19))
        #expect(field._magnifyLayer?.frame == CGRect(x: magnifierX, y: 7, width: 12, height: 12))
        #expect(field._cancelSearchLayer?.frame == CGRect(x: cancelX, y: 6, width: 14, height: 14))
        #expect(field._hostLayer.frame == CGRect(x: 25, y: 0, width: 200, height: 25))
    }

    @Test("布局把当前事务的曲线改成 ease-in-ease-out，不恢复")
    func layoutTimingFunction() throws {
        let field = makeField()
        CATransaction.flush()
        CATransaction.begin()
        defer { CATransaction.commit() }
        try #require(CATransaction.animationTimingFunction() == nil)
        field.frame = Self.frame
        let function = try #require(CATransaction.animationTimingFunction())
        let easeInEaseOut = CAMediaTimingFunction(name: .easeInEaseOut)
        for index in 0..<4 {
            var point = [Float](repeating: 0, count: 2)
            var expected = [Float](repeating: 0, count: 2)
            function.getControlPoint(at: index, values: &point)
            easeInEaseOut.getControlPoint(at: index, values: &expected)
            #expect(point == expected)
        }
    }

    // MARK: - State (REF-SEARCH-005)

    /// Records the keys a layer asks its delegate actions for; none are asked while actions are
    /// disabled.
    final class ActionRecorder: NSObject, CALayerDelegate {
        var keys: [String] = []

        func action(for layer: CALayer, forKey event: String) -> (any CAAction)? {
            keys.append(event)
            return nil
        }
    }

    @Test("设非空文字后占位文字隐藏、清除按钮显示，设空后相反，都不带隐式动画")
    func stringValue() throws {
        let field = makeField()
        let placeholder = try #require(field._placeholderLayer)
        let cancel = try #require(field._cancelSearchLayer)
        let recorder = ActionRecorder()
        placeholder.delegate = recorder
        cancel.delegate = recorder

        field.stringValue = "a"
        #expect(placeholder.isHidden)
        #expect(!cancel.isHidden)
        field.stringValue = ""
        #expect(!placeholder.isHidden)
        #expect(cancel.isHidden)
        #expect(recorder.keys.isEmpty)
        #expect(!CATransaction.disableActions())
    }

    @Test("搜索框的不透明度只会被设成 1", arguments: [
        // the change after the state it needs, the opacity after it
        ("fade on", 1.0),
        ("string not empty, focused", 1.0),
        ("string empty, focused", 0.5),
        ("string empty, not focused", 1.0),
        ("deactivated, focused", 0.5),
        ("deactivated, not focused", 1.0),
        ("focus", 1.0),
        ("focus lost", 0.5),
    ])
    func opacity(change: String, expected: Float) {
        let field = makeField()
        switch change {
        case "string not empty, focused", "string empty, focused":
            field.stringValue = "a"
            field.hasFocus = true
        case "string empty, not focused":
            field.stringValue = "a"
        case "deactivated, focused", "focus lost":
            field.hasFocus = true
        case "deactivated, not focused":
            field.textFieldActive = true
        default:
            break
        }
        field.opacity = 0.5
        switch change {
        case "fade on":
            field.fadeWhenNotActive = true
        case "string not empty, focused":
            field.stringValue = "b"
        case "string empty, focused", "string empty, not focused":
            field.stringValue = ""
        case "deactivated, focused", "deactivated, not focused":
            field.textFieldActive = false
        case "focus":
            field.hasFocus = true
        case "focus lost":
            field.hasFocus = false
        default:
            break
        }
        #expect(field.opacity == expected)
    }

    @Test("没激活时取得焦点先激活")
    func focusActivates() {
        let field = makeField()
        field.frame = Self.frame
        field.hasFocus = true
        #expect(field.textFieldActive)
        #expect(field._magnifyLayer?.frame.minX == 7)
    }

    @Test("激活和取消激活都重新布局")
    func activationLayout() {
        let field = makeField()
        field.frame = Self.frame
        field.textFieldActive = true
        #expect(field._magnifyLayer?.frame.minX == 7)
        #expect(field._placeholderLayer?.frame.minX == 27)
        field.textFieldActive = false
        #expect(field._magnifyLayer?.frame.minX == 100.5)
        #expect(field._placeholderLayer?.frame.minX == 120.5)
    }

    @Test("按下清除按钮时不透明，松开回到 0.3")
    func darkenCancelLayer() {
        let field = makeField()
        field._darkenCancelLayer(true)
        #expect(field._cancelSearchLayer?.opacity == 1)
        field._darkenCancelLayer(false)
        #expect(field._cancelSearchLayer?.opacity == 0.3)
    }
}

/// The search field and the "no results" layers in the main grid's layer (REF-SEARCH-001,
/// REF-SEARCH-002, REF-SEARCH-006), and the field's reset after closing (REF-SEARCH-005).
@MainActor
@Suite(.serialized)
struct SearchGridTests {
    init() {
        launchPadBundle = testResources
    }

    /// A one-page main grid laid out in bounds 1536 × `height`, with the margins of the original's
    /// measurement: top 35, bottom 36, no zoom.
    func makeGrid(height: CGFloat = 856, notchHeight: CGFloat = 0, scaleFactor: Float = 1,
                  layoutRTL: Bool = false) -> ECSBSpringboard {
        let grid = ECSBSpringboard(handler: PageSource(count: 1), numberOfRowsPerPage: 5, numberOfColumnsPerPage: 7,
                                   scaleFactor: scaleFactor, layoutRTL: layoutRTL)
        let saved = dockBar.display
        defer { dockBar.display = saved }
        dockBar.display = DisplayDescriptor(notchBounds: notchHeight == 0 ? .null
                                                : CGRect(x: 600, y: 0, width: 336, height: notchHeight))
        grid.invalidate()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grid.layer.frame = CGRect(x: 0, y: 104, width: 1536, height: height)
        (grid.leftMargin, grid.rightMargin, grid.topMargin, grid.bottomMargin) = (90, 90, 35, 36)
        grid.zoomFactor = 0
        grid.layout()
        CATransaction.commit()
        return grid
    }

    @Test("子 layer 依次是「无结果」容器、滚动 layer、页码指示器、搜索框")
    func sublayers() throws {
        let layer = makeGrid().layer
        let container = try #require(layer.sublayers?.first)
        let field = try #require(layer.searchTextInputLayer())
        let text = try #require(layer.noResultsLayer())
        #expect(layer.sublayers?.map(ObjectIdentifier.init) ==
                    [container, layer.scrollLayer, layer.controlLayer, field].map(ObjectIdentifier.init))
        #expect(NSStringFromClass(type(of: container)) == "CALayer")
        #expect(container.sublayers?.map(ObjectIdentifier.init) == [ObjectIdentifier(text)])
        #expect(!container.allowsGroupBlending)
    }

    @Test("「无结果」的文字 layer 按 REF-SEARCH-006 设好，开始时透明")
    func noResultsLook() throws {
        let text = try #require(makeGrid(scaleFactor: 2).layer.noResultsLayer())
        #expect(text.string as? String == "无结果")
        let font = try #require(text.font.map { $0 as! CTFont })
        #expect(CTFontCopyPostScriptName(font) as String == ".SFNS-Light")
        #expect(CTFontGetSize(font) == 40)
        #expect(text.fontSize == 40)
        let gray: [CGFloat] = [52.0 / 255.0, 1]
        #expect(text.foregroundColor?.components == gray)
        #expect(text.compositingFilter as? String == "plusL")
        let shadow: [CGFloat] = [0, 0.2]
        #expect((text.textShadowColor as! CGColor?)?.components == shadow)
        #expect(text.textShadowOffset == CGSize(width: 0, height: -1))
        #expect(text.textShadowBlur == 2)
        #expect(text.alignmentMode == .center)
        #expect(text.opacity == 0)
        #expect(text.contentsScale == 2)
    }

    @Test("搜索框按 REF-SEARCH-001 设好，事件代理是主网格 layer")
    func fieldSetup() throws {
        let layer = makeGrid(scaleFactor: 2).layer
        let field = try #require(layer.searchTextInputLayer())
        #expect(field.fadeWhenNotActive)
        let font = try #require(field.font.map { $0 as! CTFont })
        #expect(CTFontCopyPostScriptName(font) as String == ".SFNS-Light")
        #expect(CTFontGetSize(font) == 16)
        #expect(field.fontSize == 16)
        #expect(field.placeholderString == "搜索")
        #expect(field._placeholderLayer?.string as? String == "搜索")
        #expect(field.foregroundColor == CGColor(gray: 1, alpha: 1))
        #expect(field.scaleFactor == 2)
        #expect(field.contentsScale == 2)
        #expect(field.eventDelegate === layer)
        #expect(field.stringValue == nil && !field.hasFocus && !field.textFieldActive)
    }

    @Test("从右到左的主网格里，搜索框的放大镜在占位文字右边")
    func fieldRightToLeft() throws {
        let field = try #require(makeGrid(layoutRTL: true).layer.searchTextInputLayer())
        // REF-SEARCH-002, not active, right to left, with the placeholder 33 wide.
        #expect(field._placeholderLayer?.frame.minX == 96.5)
        #expect(field._magnifyLayer?.frame.minX == 137.5)
    }

    @Test("1536 × 856、上边距 35 时搜索框是 (643, 806, 250, 25)；有刘海时下移刘海的高度")
    func fieldFrame() throws {
        #expect(makeGrid().layer.searchTextInputLayer()?.frame == CGRect(x: 643, y: 806, width: 250, height: 25))
        #expect(makeGrid(notchHeight: 32).layer.searchTextInputLayer()?.frame ==
                    CGRect(x: 643, y: 774, width: 250, height: 25))
    }

    @Test("「无结果」容器在页的矩形中央、比文字大 10，文字 layer 铺满容器")
    func noResultsFrame() throws {
        let layer = makeGrid().layer
        let text = try #require(layer.noResultsLayer())
        // The original's measurement: the Chinese text 115 × 48 (REF-SEARCH-006).
        try #require(text.preferredFrameSize() == CGSize(width: 115, height: 48))
        #expect(layer.sublayers?.first?.frame == CGRect(x: 705, y: 384, width: 125, height: 58))
        #expect(text.frame == CGRect(x: 0, y: 0, width: 125, height: 58))
    }

    /// Records the keys a layer asks its delegate actions for; none are asked while actions are
    /// disabled.
    final class ActionRecorder: NSObject, CALayerDelegate {
        var keys: [String] = []

        func action(for layer: CALayer, forKey event: String) -> (any CAAction)? {
            keys.append(event)
            return nil
        }
    }

    @Test("布局时搜索框的 frame 不带隐式动画，「无结果」容器的带")
    func layoutActions() throws {
        let grid = makeGrid()
        let field = try #require(grid.layer.searchTextInputLayer())
        let container = try #require(grid.layer.sublayers?.first)
        let fieldRecorder = ActionRecorder()
        let containerRecorder = ActionRecorder()
        field.delegate = fieldRecorder
        container.delegate = containerRecorder
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grid.layer.frame.size.height = 900
        CATransaction.commit()
        let saved = dockBar.display
        defer { dockBar.display = saved }
        dockBar.display = DisplayDescriptor(notchBounds: .null)
        CATransaction.begin()
        grid.layout()
        CATransaction.commit()
        #expect(field.frame.minY == 850)
        #expect(fieldRecorder.keys.isEmpty)
        #expect(containerRecorder.keys.contains("position"))
    }
}

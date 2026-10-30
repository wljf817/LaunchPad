import CoreGraphics
import LaunchPadPrivate
import QuartzCore
import Testing
@testable import LaunchPad

// Keyboard navigation of the main grid (REF-KEYBOARD-001 to 005, research paper §9): the event's
// Command flag, the material of the selection layer, the selection layer of an item layer and the
// selected item of the pager.

/// The selection frame of REF-KEYBOARD-004, worked out here from the icon's and the name's frames.
func expectedSelectionFrame(image: CGRect, label: CGRect) -> CGRect {
    let dx: CGFloat
    if label.width <= image.width {
        dx = 15
    } else if label.width >= image.width + 15 {
        dx = 7
    } else {
        dx = 7 + max(0, 8 - ((label.width - image.width) / 2).rounded(.down))
    }
    let union = image.union(label)
    return CGRect(x: union.minX - dx, y: union.minY - 5, width: union.width + 2 * dx, height: union.height + 20)
}

/// An item layer whose icon and name have the frames given, as `-layout` would leave them.
@MainActor
func makeItemLayer(folder: Bool = false, image: CGRect, label: CGRect) -> ECSBItemLayer {
    let itemLayer = folder ? ECSBGroupItemLayer(scaleFactor: 1, layoutRTL: false) : ECSBItemLayer(scaleFactor: 1, layoutRTL: false)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    itemLayer.imageLayer.frame = image
    itemLayer.labelLayer.frame = label
    CATransaction.commit()
    return itemLayer
}

/// The image and label frames the original's item layers had at the reference layout (REF-KEYBOARD-004).
let referenceImageFrame = CGRect(x: 36, y: 42, width: 104, height: 104)
let referenceLabelFrame = CGRect(x: 55, y: 19, width: 67, height: 23)

@MainActor
@Suite(.serialized)
struct KeyboardTests {
    // MARK: - The Command flag (REF-KEYBOARD-001)

    @Test("commandKeyDown：flags 带 Command 位时为真，只带别的修饰键时为假")
    func commandKeyDown() {
        func event(_ flags: CGEventFlags) -> ECEvent {
            let key = keyEvent(124, character: 0xf703)
            key.flags = flags
            return ECEvent(event: key, hitLayer: nil, hitWindow: nil, session: nil)
        }
        #expect(event(.maskCommand).commandKeyDown)
        #expect(event([.maskCommand, .maskShift, .maskAlternate]).commandKeyDown)
        #expect(!event([]).commandKeyDown)
        #expect(!event([.maskShift, .maskAlternate, .maskControl, .maskSecondaryFn, .maskNumericPad]).commandKeyDown)
        #expect(!ECEvent(event: nil, hitLayer: nil, hitWindow: nil, session: nil).commandKeyDown)
    }

    // MARK: - Material (REF-KEYBOARD-004)

    func material(_ control: UInt, _ appearance: UInt) -> (components: [CGFloat], space: CFString?, filter: String?) {
        let layer = CALayer()
        layer.setMaterialControl(control, appearance: appearance)
        return (layer.backgroundColor?.components ?? [], layer.backgroundColor?.colorSpace?.name,
                layer.compositingFilter as? String)
    }

    @Test("材质：appearance 1 的四个 control 是 REF-KEYBOARD-004 的四个灰度，alpha 1、sRGB、plusD")
    func materialAppearance1() {
        for (control, gray) in [(0, 76.0), (1, 128.0), (2, 198.0), (3, 232.0)] {
            let value = material(UInt(control), 1)
            let component = CGFloat(gray / 255)
            #expect(value.components == [component, component, component, 1])
            #expect(value.space == CGColorSpace.sRGB)
            #expect(value.filter == "plusD")
        }
        #expect(kCAFilterPlusD == "plusD")
    }

    @Test("材质：其他 appearance 用另一张表和 plusL；control 大于 3 时灰度为 0")
    func materialOtherAppearances() {
        for appearance: UInt in [0, 2] {
            for (control, gray) in [(0, 229.0), (1, 124.0), (2, 65.0), (3, 35.0)] {
                let value = material(UInt(control), appearance)
                let component = CGFloat(gray / 255)
                #expect(value.components == [component, component, component, 1])
                #expect(value.space == CGColorSpace.sRGB)
                #expect(value.filter == "plusL")
            }
        }
        for (appearance, filter) in [(UInt(1), "plusD"), (0, "plusL")] {
            let value = material(4, appearance)
            #expect(value.components == [0, 0, 0, 1])
            #expect(value.filter == filter)
        }
    }

    // MARK: - The selection layer (REF-KEYBOARD-004)

    func expectSelectionLook(_ itemLayer: ECSBItemLayer) throws {
        let selection = try #require(itemLayer._selectionLayer)
        #expect(type(of: selection) == CALayer.self)
        #expect(itemLayer.jitterLayer.sublayers?.first === selection)
        #expect(selection.opacity == 1)
        let gray: CGFloat = 232.0 / 255
        #expect(selection.backgroundColor?.components == [gray, gray, gray, 1])
        #expect(selection.backgroundColor?.colorSpace?.name == CGColorSpace.sRGB)
        #expect(selection.compositingFilter as? String == "plusD")
        #expect(selection.cornerCurve == .circular)
        #expect(!selection.masksToBounds)
    }

    @Test("选中时选中框在 jitter layer 的第 0 位，frame、圆角、背景、合成滤镜、不透明度按 REF-KEYBOARD-004")
    func selectionLayer() throws {
        let itemLayer = makeItemLayer(image: referenceImageFrame, label: referenceLabelFrame)
        let before = itemLayer.jitterLayer.sublayers ?? []
        itemLayer.selected = true
        #expect(itemLayer.selected)
        try expectSelectionLook(itemLayer)
        #expect(Array((itemLayer.jitterLayer.sublayers ?? []).dropFirst()) == before)
        #expect(itemLayer._selectionLayer?.frame == CGRect(x: 21, y: 14, width: 134, height: 147))
        #expect(itemLayer._selectionLayer?.cornerRadius == 16)
    }

    @Test("选中框的 frame：名称不比图标宽、宽不到 15、宽 15 以上三种情形")
    func selectionFrames() {
        // The first five and the last were measured in the original (REF-KEYBOARD-004).
        let cases: [(label: CGRect, frame: CGRect)] = [
            (CGRect(x: 55, y: 19, width: 67, height: 23), CGRect(x: 21, y: 14, width: 134, height: 147)),
            (CGRect(x: 36, y: 19, width: 105, height: 23), CGRect(x: 21, y: 14, width: 135, height: 147)),
            (CGRect(x: 35, y: 19, width: 107, height: 23), CGRect(x: 21, y: 14, width: 135, height: 147)),
            (CGRect(x: 34, y: 19, width: 108, height: 23), CGRect(x: 21, y: 14, width: 134, height: 147)),
            (CGRect(x: 33, y: 19, width: 110, height: 23), CGRect(x: 21, y: 14, width: 134, height: 147)),
            (CGRect(x: 36, y: 19, width: 104, height: 23), CGRect(x: 21, y: 14, width: 134, height: 147)),
            (CGRect(x: 29, y: 19, width: 118, height: 23), CGRect(x: 21, y: 14, width: 134, height: 147)),
            (CGRect(x: 28, y: 19, width: 119, height: 23), CGRect(x: 21, y: 14, width: 133, height: 147)),
            (CGRect(x: 6, y: 19, width: 164, height: 23), CGRect(x: -1, y: 14, width: 178, height: 147)),
        ]
        for (label, frame) in cases {
            let itemLayer = makeItemLayer(image: referenceImageFrame, label: label)
            #expect(itemLayer._selectionFrame() == frame)
            #expect(frame == expectedSelectionFrame(image: referenceImageFrame, label: label))
            itemLayer.selected = true
            #expect(itemLayer._selectionLayer?.frame == frame)
        }
    }

    @Test("圆角：图标高度乘 0.15625，取整时 .5 向零")
    func selectionCornerRadius() {
        for (height, radius) in [(104.0, 16.0), (112, 17), (80, 12), (96, 15), (120, 19), (128, 20)] {
            let itemLayer = makeItemLayer(image: CGRect(x: 36, y: 42, width: height, height: height), label: referenceLabelFrame)
            itemLayer.selected = true
            #expect(itemLayer._selectionLayer?.cornerRadius == CGFloat(radius))
        }
        #expect(roundHalfTowardZero(2.5) == 2)
        #expect(roundHalfTowardZero(2.51) == 3)
        #expect(roundHalfTowardZero(0) == 0)
        #expect(roundHalfTowardZero(-2.5) == -2)
        #expect(roundHalfTowardZero(-2.51) == -3)
    }

    @Test("取消选中后选中框不透明度为 0 并被移除；值不变时什么也不做")
    func deselect() throws {
        let itemLayer = makeItemLayer(image: referenceImageFrame, label: referenceLabelFrame)
        itemLayer.selected = false
        #expect(itemLayer._selectionLayer == nil)
        let before = itemLayer.jitterLayer.sublayers ?? []
        itemLayer.selected = true
        let selection = try #require(itemLayer._selectionLayer)
        itemLayer.selected = true
        #expect(itemLayer._selectionLayer === selection)
        #expect(itemLayer.jitterLayer.sublayers?.count == before.count + 1)
        itemLayer.selected = false
        #expect(!itemLayer.selected)
        #expect(itemLayer._selectionLayer == nil)
        #expect(selection.superlayer == nil)
        #expect(selection.opacity == 0)
        #expect(itemLayer.jitterLayer.sublayers ?? [] == before)
    }

    @Test("隐式动画：调用前开着时调用后仍开着，关着时仍关着；选中和取消选中都没有动画")
    func selectionWithoutAnimation() throws {
        let scene = SceneGrid()
        let itemLayer = scene.itemLayer(0)
        // A committed layer next to it animates an implicit change (the checks below are not vacuous).
        let probe = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scene.itemLayer(1).jitterLayer.addSublayer(probe)
        CATransaction.commit()
        CATransaction.flush()
        defer { probe.removeFromSuperlayer() }

        CATransaction.begin()
        probe.opacity = 0.5
        itemLayer.selected = true
        #expect(!CATransaction.disableActions())
        CATransaction.commit()
        CATransaction.flush()
        #expect(probe.animation(forKey: "opacity") != nil)
        let selection = try #require(itemLayer._selectionLayer)
        #expect(selection.animationKeys() == nil)
        #expect(itemLayer.jitterLayer.animationKeys() == nil)

        CATransaction.begin()
        itemLayer.selected = false
        #expect(!CATransaction.disableActions())
        CATransaction.commit()
        #expect(selection.animationKeys() == nil)
        #expect(itemLayer.jitterLayer.animationKeys() == nil)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        itemLayer.selected = true
        #expect(CATransaction.disableActions())
        itemLayer.selected = false
        #expect(CATransaction.disableActions())
        CATransaction.commit()
    }

    @Test("-layout 后选中框的 frame 跟着图标和名称的 frame 变，圆角不变")
    func selectionFollowsLayout() throws {
        let scene = SceneGrid()
        let itemLayer = scene.itemLayer(0)
        itemLayer.selected = true
        defer { itemLayer.selected = false }
        let selection = try #require(itemLayer._selectionLayer)
        #expect(selection.frame == expectedSelectionFrame(image: itemLayer.imageLayer.frame, label: itemLayer.labelLayer.frame))
        let radius = selection.cornerRadius
        let before = selection.frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        itemLayer.bounds = CGRect(x: 0, y: 0, width: 120, height: 120)
        itemLayer.layout()
        CATransaction.commit()
        #expect(selection.frame != before)
        #expect(selection.frame == expectedSelectionFrame(image: itemLayer.imageLayer.frame, label: itemLayer.labelLayer.frame))
        #expect(selection.cornerRadius == radius)
    }

    @Test("文件夹图标（ECSBGroupItemLayer）选中时结果相同")
    func folderSelection() throws {
        let itemLayer = makeItemLayer(folder: true, image: referenceImageFrame, label: referenceLabelFrame)
        itemLayer.selected = true
        try expectSelectionLook(itemLayer)
        #expect(itemLayer._selectionLayer?.frame == CGRect(x: 21, y: 14, width: 134, height: 147))
        #expect(itemLayer._selectionLayer?.cornerRadius == 16)
        itemLayer.selected = false
        #expect(itemLayer._selectionLayer == nil)
    }
}

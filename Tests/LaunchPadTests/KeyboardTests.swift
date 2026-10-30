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

    // MARK: - The selected item (REF-KEYBOARD-003)

    @Test("换选中项的先后：将要改变、旧项取消选中、存下新项、新项选中、已经改变；参数是模型项和 pager")
    func selectionCallbacks() {
        let pager = ECSBPager(pagerSource: nil, scaleFactor: 1, layoutRTL: false)
        let recorder = SelectionRecorder(pager: pager)
        pager.handler = recorder
        let (a, b) = (recorder.item("A"), recorder.item("B"))
        pager.selectedItem = a
        #expect(recorder.log == ["will nil → A, stored nil", "A selected true, stored A", "A done, stored A",
                                 "did nil → A, stored A"])
        recorder.log.removeAll()
        pager.selectedItem = b
        #expect(recorder.log == ["will A → B, stored A", "A selected false, stored A", "A done, stored A",
                                 "B selected true, stored B", "B done, stored B", "did A → B, stored B"])
        recorder.log.removeAll()
        pager.selectedItem = nil
        #expect(recorder.log == ["will B → nil, stored B", "B selected false, stored B", "B done, stored B",
                                 "did B → nil, stored nil"])
        #expect(recorder.pagers.allSatisfy { $0 === pager })
        #expect(recorder.pagers.count == 6)
    }

    @Test("设成同一项时不发回调，也不碰 item layer")
    func sameSelection() {
        let pager = ECSBPager(pagerSource: nil, scaleFactor: 1, layoutRTL: false)
        let recorder = SelectionRecorder(pager: pager)
        pager.handler = recorder
        pager.selectedItem = nil
        #expect(recorder.log.isEmpty)
        let a = recorder.item("A")
        pager.selectedItem = a
        recorder.log.removeAll()
        pager.selectedItem = a
        #expect(recorder.log.isEmpty)
        #expect(recorder.layers["A"]?.selected == true)
    }

    @Test("handler 不响应选中回调时照样换，item layer 照样选中和取消选中")
    func selectionWithoutCallbacks() {
        let pager = ECSBPager(pagerSource: nil, scaleFactor: 1, layoutRTL: false)
        let recorder = SelectionRecorder(pager: pager)
        let source = PageSource(count: 0)
        pager.handler = source
        let (a, b) = (recorder.item("A"), recorder.item("B"))
        pager.selectedItem = a
        #expect(pager.selectedItem === a)
        #expect(recorder.layers["A"]?.selected == true)
        pager.selectedItem = b
        #expect(pager.selectedItem === b)
        #expect(recorder.layers["A"]?.selected == false)
        #expect(recorder.layers["B"]?.selected == true)
        #expect(recorder.log == ["A selected true, stored A", "A done, stored A", "A selected false, stored A",
                                 "A done, stored A", "B selected true, stored B", "B done, stored B"])
        withExtendedLifetime(source) {}
    }

    @Test("ECSBSpringboard 的 selectedItem 是模型项；设模型项时找到它的 ECSBItem 交给 pager")
    func springboardSelectedItem() {
        let scene = SceneGrid()
        let items = scene.page.item.items as! [ECSBItem]
        let client = items[3].clientItem
        scene.grid.selectedItem = client
        #expect(scene.grid.pager.selectedItem === items[3])
        #expect(scene.grid.selectedItem === client)
        #expect(scene.itemLayer(3).selected)
        let other = items[5].clientItem
        scene.grid.selectedItem = other
        #expect(scene.grid.pager.selectedItem === items[5])
        #expect(scene.grid.selectedItem === other)
        #expect(!scene.itemLayer(3).selected)
        #expect(scene.itemLayer(5).selected)
        scene.grid.pager.selectedItem = nil
    }

    @Test("打开、关闭、重建、换页、在图标上按下都清掉选中项并取消 item layer 的选中")
    func selectionCleared() {
        let scene = SceneGrid(emptyPages: 1)
        let pager = scene.grid.pager
        let items = scene.page.item.items as! [ECSBItem]
        func select() {
            pager.selectedItem = items[2]
            #expect(scene.itemLayer(2).selected)
        }
        select()
        scene.grid.setVisible(true)
        #expect(pager.selectedItem == nil)
        #expect(!scene.itemLayer(2).selected)
        select()
        scene.grid.setVisible(false)
        #expect(pager.selectedItem == nil)
        #expect(!scene.itemLayer(2).selected)

        select()
        scene.grid.currentPageIndex = 1
        #expect(pager.selectedItem == nil)
        #expect(!scene.itemLayer(2).selected)
        scene.grid.currentPageIndex = 0
        scene.grid.layer.scrollLayer.removeAllAnimations()

        select()
        let actions = RecordingGridActions()
        pager.gridActionHandler = actions
        let handler = RecordingHandler(layer: scene.top)
        let controller = ECModalEventController.sharedController()
        controller.addHandler(handler, externalEventSource: true, usingMouseHysteresis: true)
        scene.send(.leftMouseDown, scene.icon(5))
        #expect(pager.selectedItem == nil)
        #expect(!scene.itemLayer(2).selected)
        scene.send(.leftMouseUp, scene.icon(5))
        controller.removeHandler(handler)

        select()
        let itemLayer = scene.itemLayer(2)
        scene.grid.invalidate()
        #expect(pager.selectedItem == nil)
        #expect(!itemLayer.selected)
    }

    @Test("Springboard 响应两个选中回调，是主网格 pager 的 handler")
    func springboardCallbacks() {
        let controller = QuietSpringboard()
        #expect(controller.springboard.pager.handler === controller)
        #expect(controller.responds(to: #selector(ECSBDelegate.selectionWillChange(fromItem:toItem:inPager:))))
        #expect(controller.responds(to: #selector(ECSBDelegate.selectionDidChange(fromItem:toItem:inPager:))))
    }
}

/// An item layer that logs when its selected look changes, with what the pager has stored then.
@MainActor
final class RecordingItemLayer: ECSBItemLayer {
    var tag = ""
    weak var recorder: SelectionRecorder?

    override var selected: Bool {
        get { super.selected }
        set {
            recorder?.log.append("\(tag) selected \(newValue), stored \(recorder?.storedName ?? "?")")
            super.selected = newValue
            recorder?.log.append("\(tag) done, stored \(recorder?.storedName ?? "?")")
        }
    }
}

/// A grid handler that records the selection callbacks, and the items and layers it made.
@MainActor
final class SelectionRecorder: NSObject, ECSBDataSource, ECSBDelegate {
    final class Client: NSObject {
        let name: String
        init(name: String) { self.name = name }
    }

    weak var pager: ECSBPager?
    var log: [String] = []
    var pagers: [AnyObject?] = []
    var clients: [Client] = []
    var items: [ECSBItem] = []
    var layers: [String: RecordingItemLayer] = [:]

    init(pager: ECSBPager) {
        self.pager = pager
    }

    /// A grid item standing for a new model item called `name`, with a recording layer.
    func item(_ name: String) -> ECSBItem {
        let client = Client(name: name)
        let item = ECSBItem()
        item.clientItem = client
        let itemLayer = RecordingItemLayer(scaleFactor: 1, layoutRTL: false)
        itemLayer.tag = name
        itemLayer.recorder = self
        item.itemLayer = itemLayer
        clients.append(client)
        items.append(item)
        layers[name] = itemLayer
        return item
    }

    var storedName: String {
        name(pager?.selectedItem?.clientItem)
    }

    func name(_ client: AnyObject?) -> String {
        (client as? Client)?.name ?? "nil"
    }

    func value(forKey key: String, ofItem item: AnyObject?, withInfo info: AnyObject?) -> AnyObject? { nil }

    func selectionWillChange(fromItem oldItem: AnyObject?, toItem newItem: AnyObject?, inPager pager: AnyObject?) {
        log.append("will \(name(oldItem)) → \(name(newItem)), stored \(storedName)")
        pagers.append(pager)
    }

    func selectionDidChange(fromItem oldItem: AnyObject?, toItem newItem: AnyObject?, inPager pager: AnyObject?) {
        log.append("did \(name(oldItem)) → \(name(newItem)), stored \(storedName)")
        pagers.append(pager)
    }
}

// MARK: - Navigation (REF-KEYBOARD-002)

/// The navigation types (REF-KEYBOARD-001).
let navigateUp: Int64 = 0
let navigateDown: Int64 = 1
let navigateLeft: Int64 = 2
let navigateRight: Int64 = 3

/// The characters of the keys (REF-KEYBOARD-001).
enum KeyCharacter {
    static let up: Int64 = 0xF700
    static let down: Int64 = 0xF701
    static let left: Int64 = 0xF702
    static let right: Int64 = 0xF703
    static let home: Int64 = 0xF729
    static let end: Int64 = 0xF72B
    static let pageUp: Int64 = 0xF72C
    static let pageDown: Int64 = 0xF72D
    static let tab: Int64 = 0x09
    static let enter: Int64 = 0x03
    static let `return`: Int64 = 0x0D
    static let escape: Int64 = 0x1B
    static let space: Int64 = 0x20
    static let a: Int64 = 0x61
}

/// A key event with the character given, with Command or without any modifier.
@MainActor
func key(_ character: Int64, command: Bool = false, down: Bool = true) -> ECEvent {
    let cgEvent = keyEvent(0, character: character, down: down)
    cgEvent.flags = command ? .maskCommand : []
    return ECEvent(event: cgEvent, hitLayer: nil, hitWindow: nil, session: nil)
}

/// A main grid whose pages hold `counts` apps each, laid out as `PagingTests.makeGrid` lays out its
/// grid, with a pager that records the key and navigation calls.
@MainActor
final class KeyGrid {
    let source: KeyGridSource
    let grid: ECSBSpringboard
    let pager: RecordingPager

    init(_ counts: [Int], rtl: Bool = false) {
        source = KeyGridSource(counts: counts)
        grid = ECSBSpringboard(handler: source, numberOfRowsPerPage: 5, numberOfColumnsPerPage: 7, scaleFactor: 1,
                               layoutRTL: rtl)
        // Wired as ECSBSpringboard's initializer wires its own pager.
        pager = RecordingPager(pagerSource: grid, scaleFactor: 1, layoutRTL: rtl)
        pager.gridActionHandler = grid
        pager.handler = source
        pager.eventHandler = grid.eventHandler
        grid._pager = pager
        let saved = dockBar.display
        dockBar.display = DisplayDescriptor(notchBounds: .null)
        grid.invalidate()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grid.layer.frame = CGRect(x: 0, y: 101, width: 1536, height: 859)
        (grid.leftMargin, grid.rightMargin, grid.topMargin, grid.bottomMargin) = (90, 90, 35, 37)
        grid.zoomFactor = 0.2
        grid.layout()
        CATransaction.commit()
        dockBar.display = saved
        reset()
    }

    func page(_ index: Int) -> ECSBPage {
        (pager.pages as! [ECSBPage])[index]
    }

    func item(_ page: Int, _ index: Int) -> ECSBItem {
        self.page(page).item.items![index] as! ECSBItem
    }

    /// The page and the index of the selected item; nil without one.
    var selection: [Int]? {
        guard let selected = pager.selectedItem else { return nil }
        for (index, page) in (pager.pages as! [ECSBPage]).enumerated() {
            let position = page.item.items!.indexOfObjectIdentical(to: selected)
            if position != NSNotFound {
                return [index, position]
            }
        }
        return [-1, -1]
    }

    /// Selects an item, then forgets the calls so far.
    func select(_ page: Int, _ index: Int) {
        pager.selectedItem = item(page, index)
        source.selections.removeAll()
    }

    /// Moves to a page without a selected item, then forgets the calls so far.
    func show(_ page: Int) {
        pager.currentPageIndex = UInt(page)
        pager.selectedItem = nil
        reset()
    }

    func reset() {
        pager.log.removeAll()
        source.selections.removeAll()
        source.actions.removeAll()
    }

    /// The item layers of a page that show the selection.
    func selectedLayers(_ page: Int) -> [Int] {
        (self.page(page).item.items as! [ECSBItem]).enumerated().compactMap { $1.itemLayer?.selected == true ? $0 : nil }
    }
}

/// Pages of apps with the item counts given, as the layout root's children. It records the selection
/// changes and the actions on items.
@MainActor
final class KeyGridSource: NSObject, ECSBDataSource, ECSBDelegate, ECSBActionHandling {
    final class Node: NSObject {
        let kind: String
        let children: [Node]

        init(_ kind: String, _ children: [Node] = []) {
            self.kind = kind
            self.children = children
        }
    }

    let pages: [Node]
    let icon = SceneDataSource.image(96)
    var selections: [(from: AnyObject?, to: AnyObject?)] = []
    var actions: [(item: AnyObject?, event: ECEvent?, sender: AnyObject?)] = []

    init(counts: [Int]) {
        pages = counts.map { count in Node("page", (0..<count).map { _ in Node("item") }) }
    }

    func value(forKey key: String, ofItem item: AnyObject?, withInfo info: AnyObject?) -> AnyObject? {
        guard let node = item as? Node else {
            return key == "items" ? pages as NSArray : nil
        }
        switch key {
        case "items": return node.children as NSArray
        case "kind": return node.kind as NSString
        case "title": return "" as NSString
        case "icon": return icon
        default: return nil
        }
    }

    func selectionDidChange(fromItem oldItem: AnyObject?, toItem newItem: AnyObject?, inPager pager: AnyObject?) {
        selections.append((oldItem, newItem))
    }

    func performAction(forItem item: AnyObject?, with event: ECEvent?, sender: AnyObject?) {
        actions.append((item, event, sender))
    }
}

/// A main grid pager that logs its key and navigation calls in the order they start, each with its
/// result, and whose layer logs its own.
@MainActor
final class RecordingPager: ECSBPager {
    var log: [String] = []

    func record(_ name: String, _ body: () -> Bool) -> Bool {
        let index = log.count
        log.append(name)
        let result = body()
        log[index] += result ? " YES" : " NO"
        return result
    }

    override func pagerLayerClass() -> ECPagerLayer.Type {
        KeyRecordingLayer.self
    }

    override func navigate(_ type: Int64, with event: ECEvent?) -> Bool {
        record("pager navigate \(type)") { super.navigate(type, with: event) }
    }

    override func keyDown(_ event: ECEvent) -> Bool {
        record("pager keyDown") { super.keyDown(event) }
    }

    override func keyUp(_ event: ECEvent) -> Bool {
        record("pager keyUp") { super.keyUp(event) }
    }

    override func performAction(_ event: ECEvent?) -> Bool {
        record("pager performAction") { super.performAction(event) }
    }
}

/// The pager layer of a `RecordingPager`.
@MainActor
final class KeyRecordingLayer: ECSBLayer {
    var recorder: RecordingPager? {
        pager as? RecordingPager
    }

    override func setCurrentPageIndex(_ index: UInt) {
        recorder?.log.append("setCurrentPageIndex \(index)")
        super.setCurrentPageIndex(index)
    }

    override func keyDown(_ event: ECEvent) -> Bool {
        recorder?.record("layer keyDown") { super.keyDown(event) } ?? super.keyDown(event)
    }

    override func keyUp(_ event: ECEvent) -> Bool {
        recorder?.record("layer keyUp") { super.keyUp(event) } ?? super.keyUp(event)
    }
}

@MainActor
@Suite(.serialized)
struct KeyboardNavigationTests {
    // MARK: - In a page (REF-KEYBOARD-002)

    @Test("没有选中项时 → 和 ↓ 选中当前页的第一项，← 和 ↑ 选中最后一项；31 项和 35 项的页")
    func firstKey() {
        for count in [31, 35] {
            let keys = KeyGrid([count])
            for (type, expected) in [(navigateRight, 0), (navigateDown, 0), (navigateLeft, count - 1), (navigateUp, count - 1)] {
                keys.show(0)
                #expect(keys.page(0).navigate(type, with: nil))
                #expect(keys.selection == [0, expected])
                #expect(keys.source.selections.count == 1)
                #expect(keys.selectedLayers(0) == [expected])
            }
        }
    }

    @Test("← 和 → 按顺序移动一项，行尾接下一行的行首，行首退回上一行的行尾")
    func leftAndRight() {
        for count in [31, 35] {
            let keys = KeyGrid([count])
            for (from, type, to) in [(6, navigateRight, 7), (27, navigateRight, 28), (7, navigateLeft, 6), (12, navigateRight, 13),
                                     (12, navigateLeft, 11)] {
                keys.select(0, from)
                #expect(keys.page(0).navigate(type, with: nil))
                #expect(keys.selection == [0, to])
                #expect(keys.source.selections.count == 1)
                #expect(keys.selectedLayers(0) == [to])
            }
        }
    }

    @Test("↓ 从第 0 项依次选中第 7、14、21、28 项，下面没有项时不变；↑ 反过来")
    func upAndDown() {
        for count in [31, 35] {
            let keys = KeyGrid([count])
            keys.select(0, 0)
            for expected in [7, 14, 21, 28] {
                #expect(keys.page(0).navigate(navigateDown, with: nil))
                #expect(keys.selection == [0, expected])
            }
            #expect(!keys.page(0).navigate(navigateDown, with: nil))
            #expect(keys.selection == [0, 28])
            for expected in [21, 14, 7, 0] {
                #expect(keys.page(0).navigate(navigateUp, with: nil))
                #expect(keys.selection == [0, expected])
            }
            #expect(!keys.page(0).navigate(navigateUp, with: nil))
            #expect(keys.selection == [0, 0])
            #expect(keys.source.selections.count == 8)
            // Item 27: 34 is below it only on the page of 35.
            keys.select(0, 27)
            #expect(keys.page(0).navigate(navigateDown, with: nil) == (count == 35))
            #expect(keys.selection == [0, count == 35 ? 34 : 27])
            keys.select(0, 30)
            #expect(keys.page(0).navigate(navigateUp, with: nil))
            #expect(keys.selection == [0, 23])
        }
    }

    @Test("页的两端：第一项按 ← 或 ↑、最后一项按 → 都不变，返回 NO，不换页")
    func pageEnds() {
        for count in [31, 35] {
            let keys = KeyGrid([count, 10])
            for (index, type) in [(0, navigateLeft), (0, navigateUp), (count - 1, navigateRight)] {
                keys.select(0, index)
                #expect(!keys.page(0).navigate(type, with: nil))
                #expect(keys.selection == [0, index])
                #expect(keys.source.selections.isEmpty)
                #expect(keys.pager.currentPageIndex == 0)
            }
        }
    }

    @Test("从右到左：没有选中项时 ← 选中第一项，再按 → 不变；← 和 → 对调，↑ 和 ↓ 不变")
    func rightToLeft() {
        let keys = KeyGrid([31], rtl: true)
        #expect(keys.page(0).navigate(navigateLeft, with: nil))
        #expect(keys.selection == [0, 0])
        #expect(!keys.page(0).navigate(navigateRight, with: nil))
        #expect(keys.selection == [0, 0])
        #expect(keys.page(0).navigate(navigateLeft, with: nil))
        #expect(keys.selection == [0, 1])
        #expect(keys.page(0).navigate(navigateRight, with: nil))
        #expect(keys.selection == [0, 0])
        keys.select(0, 30)
        #expect(!keys.page(0).navigate(navigateLeft, with: nil))
        keys.show(0)
        #expect(keys.page(0).navigate(navigateRight, with: nil))
        #expect(keys.selection == [0, 30])
        keys.show(0)
        #expect(keys.page(0).navigate(navigateDown, with: nil))
        #expect(keys.selection == [0, 0])
        #expect(keys.page(0).navigate(navigateDown, with: nil))
        #expect(keys.selection == [0, 7])
    }

    @Test("空页返回 NO；类型 4–9 返回 NO；选中项在别的页上时四个方向键返回 NO；改变选中项时返回 YES")
    func pageResults() {
        let empty = KeyGrid([0])
        for type: Int64 in 0...9 {
            #expect(!empty.page(0).navigate(type, with: nil))
        }
        #expect(empty.selection == nil)

        let keys = KeyGrid([31, 35])
        for type: Int64 in 4...9 {
            keys.show(0)
            #expect(!keys.page(0).navigate(type, with: nil))
            #expect(keys.selection == nil)
            keys.select(0, 10)
            #expect(!keys.page(0).navigate(type, with: nil))
            #expect(keys.selection == [0, 10])
        }
        keys.select(1, 10)
        for type: Int64 in 0...3 {
            #expect(!keys.page(0).navigate(type, with: nil))
            #expect(keys.selection == [1, 10])
        }
        #expect(keys.source.selections.isEmpty)
        #expect(keys.page(1).navigate(navigateRight, with: nil))
        #expect(keys.selection == [1, 11])
    }

    // MARK: - Pages (REF-KEYBOARD-002)

    @Test("有选中项时 Cmd-→ 换到下一页并选中它的第一项；Cmd-← 换到上一页，也选中第一项")
    func commandWithSelection() {
        let keys = KeyGrid([35, 35, 10])
        keys.select(0, 1)
        #expect(keys.pager.navigate(navigateRight, with: key(KeyCharacter.right, command: true)))
        #expect(keys.pager.currentPageIndex == 1)
        #expect(keys.selection == [1, 0])
        #expect(keys.selectedLayers(0).isEmpty && keys.selectedLayers(1) == [0])
        keys.select(1, 12)
        #expect(keys.pager.navigate(navigateLeft, with: key(KeyCharacter.left, command: true)))
        #expect(keys.pager.currentPageIndex == 0)
        #expect(keys.selection == [0, 0])
        #expect(keys.selectedLayers(0) == [0] && keys.selectedLayers(1).isEmpty)
    }

    @Test("没有选中项时 Cmd-→ 换页后选中旧页的第一项，新页上没有选中框；之后的 → 在旧页上移动")
    func commandRightWithoutSelection() {
        let keys = KeyGrid([35, 35, 10])
        #expect(keys.pager.navigate(navigateRight, with: key(KeyCharacter.right, command: true)))
        #expect(keys.pager.currentPageIndex == 1)
        #expect(keys.selection == [0, 0])
        #expect(keys.selectedLayers(1).isEmpty)
        #expect(keys.pager.log == ["pager navigate 3 YES", "setCurrentPageIndex 1"])
        #expect(keys.pager.navigate(navigateRight, with: key(KeyCharacter.right)))
        #expect(keys.pager.currentPageIndex == 1)
        #expect(keys.selection == [0, 1])
    }

    @Test("没有选中项时 Cmd-← 换页以后没有选中项")
    func commandLeftWithoutSelection() {
        let keys = KeyGrid([35, 35, 10])
        keys.show(1)
        #expect(keys.pager.navigate(navigateLeft, with: key(KeyCharacter.left, command: true)))
        #expect(keys.pager.currentPageIndex == 0)
        #expect(keys.selection == nil)
        #expect(keys.source.selections.isEmpty)
    }

    @Test("换不了页时按普通的左右键：最后一页 Cmd-→、第一页 Cmd-←")
    func commandAtEnds() {
        let keys = KeyGrid([35, 35, 10])
        keys.show(2)
        keys.select(2, 0)
        #expect(keys.pager.navigate(navigateRight, with: key(KeyCharacter.right, command: true)))
        #expect(keys.pager.currentPageIndex == 2)
        #expect(keys.selection == [2, 1])
        keys.show(0)
        #expect(keys.pager.navigate(navigateLeft, with: key(KeyCharacter.left, command: true)))
        #expect(keys.pager.currentPageIndex == 0)
        #expect(keys.selection == [0, 34])
        keys.select(0, 0)
        #expect(!keys.pager.navigate(navigateLeft, with: key(KeyCharacter.left, command: true)))
        #expect(keys.selection == [0, 0])
        #expect(!keys.pager.log.contains { $0.hasPrefix("setCurrentPageIndex") })
    }

    @Test("拖动中返回 NO；有拖动捕获时换不了页，按普通的左右键")
    func whileDragging() {
        let keys = KeyGrid([35, 35, 10])
        keys.show(1)
        let capture = ECSBDragCapture(itemLayer: keys.item(1, 3).itemLayer!, fromPage: keys.page(1),
                                      usingEventHandler: keys.grid.eventHandler)
        keys.grid.eventHandler.dragCapture = capture
        defer { keys.grid.eventHandler.dragCapture = nil }
        capture._dragging = true
        for type: Int64 in 0...9 {
            #expect(!keys.pager.navigate(type, with: key(KeyCharacter.right, command: true)))
            #expect(!keys.pager.navigate(type, with: key(KeyCharacter.right)))
        }
        #expect(keys.selection == nil)
        #expect(keys.pager.currentPageIndex == 1)
        capture._dragging = false
        #expect(!keys.pager.canScroll())
        #expect(keys.pager.navigate(navigateLeft, with: key(KeyCharacter.left, command: true)))
        #expect(keys.pager.currentPageIndex == 1)
        #expect(keys.selection == [1, 34])
        #expect(!keys.pager.navigate(navigateRight, with: key(KeyCharacter.right, command: true)))
        #expect(keys.selection == [1, 34])
        keys.select(1, 0)
        #expect(keys.pager.navigate(navigateRight, with: key(KeyCharacter.right, command: true)))
        #expect(keys.pager.currentPageIndex == 1)
        #expect(keys.selection == [1, 1])
        #expect(!keys.pager.log.contains { $0.hasPrefix("setCurrentPageIndex") })
    }

    @Test("从右到左时 Cmd-← 换到下一页，Cmd-→ 换到上一页")
    func commandRightToLeft() {
        let keys = KeyGrid([35, 35, 10], rtl: true)
        keys.select(0, 1)
        #expect(keys.pager.navigate(navigateLeft, with: key(KeyCharacter.left, command: true)))
        #expect(keys.pager.currentPageIndex == 1)
        #expect(keys.selection == [1, 0])
        #expect(keys.pager.navigate(navigateRight, with: key(KeyCharacter.right, command: true)))
        #expect(keys.pager.currentPageIndex == 0)
        #expect(keys.selection == [0, 0])
        // On the first page Command-Right cannot change the page: Right right to left goes back.
        keys.show(0)
        #expect(keys.pager.navigate(navigateRight, with: key(KeyCharacter.right, command: true)))
        #expect(keys.pager.currentPageIndex == 0)
        #expect(keys.selection == [0, 34])
        // Without a selection Command-Left scrolls on and selects the first item of the page it left.
        keys.show(0)
        #expect(keys.pager.navigate(navigateLeft, with: key(KeyCharacter.left, command: true)))
        #expect(keys.pager.currentPageIndex == 1)
        #expect(keys.selection == [0, 0])
    }

    @Test("Cmd-↑、Cmd-↓ 按普通的 ↑、↓；不带 Cmd 的左右键不换页；类型 6–9 返回 NO")
    func otherKeysOnThePager() {
        let keys = KeyGrid([35, 35, 10])
        keys.select(0, 0)
        #expect(keys.pager.navigate(navigateDown, with: key(KeyCharacter.down, command: true)))
        #expect(keys.selection == [0, 7])
        #expect(keys.pager.navigate(navigateUp, with: key(KeyCharacter.up, command: true)))
        #expect(keys.selection == [0, 0])
        keys.select(0, 34)
        #expect(!keys.pager.navigate(navigateRight, with: key(KeyCharacter.right)))
        #expect(keys.pager.navigate(navigateLeft, with: nil))
        #expect(keys.selection == [0, 33])
        for type: Int64 in 6...9 {
            #expect(!keys.pager.navigate(type, with: key(KeyCharacter.home)))
            keys.show(0)
            #expect(!keys.pager.navigate(type, with: key(KeyCharacter.home)))
            keys.select(0, 33)
        }
        #expect(keys.pager.currentPageIndex == 0)
        #expect(keys.selection == [0, 33])
        #expect(!keys.pager.log.contains { $0.hasPrefix("setCurrentPageIndex") })
    }

    @Test("类型 4、5 不看 Cmd 换页；4 只在原来有选中项时返回 YES；从右到左对调")
    func accessibilityTypes() {
        let keys = KeyGrid([35, 35, 10])
        #expect(!keys.pager.navigate(4, with: nil))
        #expect(keys.pager.currentPageIndex == 1)
        #expect(keys.selection == nil)
        keys.select(1, 3)
        #expect(keys.pager.navigate(4, with: nil))
        #expect(keys.pager.currentPageIndex == 2)
        #expect(keys.selection == [2, 0])
        #expect(!keys.pager.navigate(4, with: nil))
        #expect(keys.pager.currentPageIndex == 2)
        #expect(keys.pager.navigate(5, with: nil))
        #expect(keys.pager.currentPageIndex == 1)
        #expect(keys.selection == [1, 0])
        keys.show(1)
        #expect(keys.pager.navigate(5, with: nil))
        #expect(keys.pager.currentPageIndex == 0)
        #expect(keys.selection == nil)
        #expect(!keys.pager.navigate(5, with: nil))

        let rtl = KeyGrid([35, 35, 10], rtl: true)
        #expect(rtl.pager.navigate(5, with: nil) == false)
        #expect(rtl.pager.currentPageIndex == 1)
        #expect(rtl.pager.navigate(4, with: nil))
        #expect(rtl.pager.currentPageIndex == 0)
    }

    @Test("换页走 -setCurrentPageIndex:，滚动 layer 的动画与点圆点换页相同（REF-PAGING-002）")
    func pageChangeAnimation() throws {
        WindowTests.waitForMenuBar()
        let display = CGMainDisplayID()
        let window = WALayerKitWindow(frame: CGDisplayBounds(display), connection: UInt32(bitPattern: CGSMainConnectionID()),
                                      display: display, tags: 0x400, level: 20)
        let keys = KeyGrid([35, 35, 10])
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.layer.addSublayer(keys.grid.layer)
        CATransaction.commit()
        CATransaction.flush()
        UserDefaults.standard.removeObject(forKey: "springboard-page-duration")
        springboardPageDuration = -1
        defer {
            keys.grid.layer.removeFromSuperlayer()
            springboardPageDuration = -1
        }
        let scrollLayer = keys.grid.layer.scrollLayer
        let before = scrollLayer.bounds
        keys.select(0, 4)
        #expect(keys.pager.navigate(navigateRight, with: key(KeyCharacter.right, command: true)))
        #expect(keys.pager.log == ["pager navigate 3 YES", "setCurrentPageIndex 1"])
        let animation = try #require(scrollLayer.animation(forKey: "bounds") as? CABasicAnimation)
        #expect(animation.duration == 0.5)
        var points: [[Float]] = []
        for index in 0..<4 {
            var point: [Float] = [0, 0]
            animation.timingFunction?.getControlPoint(at: index, values: &point)
            points.append(point)
        }
        // REF-PAGING-002: (0, 0, 0.35841, 1.0019), single precision 0x3EB78184 and 0x3F803E42.
        #expect(points[1] == [0, 0])
        #expect(points[2].map(\.bitPattern) == [0x3EB7_8184, 0x3F80_3E42])
        #expect((animation.fromValue as? NSValue)?.rectValue == before)
        #expect(scrollLayer.bounds.minX == 1536)
        scrollLayer.removeAllAnimations()
    }

    @Test("ECSBSpringboard 的导航交给 pager；Springboard 的 -navigate: 不带事件，所以 Cmd 不起作用")
    func springboardNavigation() {
        let keys = KeyGrid([35, 35, 10])
        #expect(keys.grid.navigate(navigateRight, with: key(KeyCharacter.right, command: true)))
        #expect(keys.pager.log == ["pager navigate 3 YES", "setCurrentPageIndex 1"])
        #expect(keys.selection == [0, 0])

        let controller = RecordingSpringboard()
        controller.springboard = keys.grid
        keys.show(0)
        controller.navigate(navigateRight)
        #expect(keys.pager.log == ["pager navigate 3 YES"])
        #expect(keys.pager.currentPageIndex == 0)
        #expect(keys.selection == [0, 0])
        keys.reset()
        controller.navigate(4)
        #expect(keys.pager.log == ["pager navigate 4 YES", "setCurrentPageIndex 1"])
        #expect(keys.selection == [1, 0])
    }
}

@MainActor
@Suite(.serialized)
struct KeyRoutingTests {
    /// Every key the routing tests press, with whether the grid layer keeps it (REF-KEYBOARD-001).
    let keptKeys: [(name: String, event: () -> ECEvent, kept: Bool)] = [
        ("Up", { key(KeyCharacter.up) }, true),
        ("Down", { key(KeyCharacter.down) }, true),
        ("Left", { key(KeyCharacter.left) }, true),
        ("Right", { key(KeyCharacter.right) }, true),
        ("Command-Up", { key(KeyCharacter.up, command: true) }, true),
        ("Command-Left", { key(KeyCharacter.left, command: true) }, true),
        ("Command-Right", { key(KeyCharacter.right, command: true) }, true),
        ("Return", { key(KeyCharacter.return) }, true),
        ("Enter", { key(KeyCharacter.enter) }, true),
        ("Escape", { key(KeyCharacter.escape) }, true),
        ("Tab", { key(KeyCharacter.tab) }, true),
        ("Home", { key(KeyCharacter.home) }, false),
        ("End", { key(KeyCharacter.end) }, false),
        ("Page Up", { key(KeyCharacter.pageUp) }, false),
        ("Page Down", { key(KeyCharacter.pageDown) }, false),
        ("a", { key(KeyCharacter.a) }, false),
        ("Command-a", { key(KeyCharacter.a, command: true) }, false),
        ("Space", { key(KeyCharacter.space) }, false),
    ]

    /// A visible controller whose main grid is `keys`'s.
    func makeController(_ keys: KeyGrid) -> RecordingSpringboard {
        let controller = RecordingSpringboard()
        controller.springboard = keys.grid
        controller._visible = true
        return controller
    }

    // MARK: - The grid layer (REF-KEYBOARD-001)

    @Test("ECSBLayer：决定的键置位并返回 NO，其余的键（含 Home、End、翻页键、字母、空格）清掉那一位并返回 NO；抬起总是 NO")
    func gridLayerKeys() {
        let keys = KeyGrid([35])
        let layer = keys.grid.layer
        for (name, event, kept) in keptKeys {
            layer.keyDownHandled = !kept
            #expect(!layer.keyDown(event()), "\(name)")
            #expect(layer.keyDownHandled == kept, "\(name)")
            #expect(!layer.keyUp(key(Int64(event().keyData), down: false)), "\(name)")
            #expect(layer.keyDownHandled == kept, "\(name)")
        }
        #expect(keys.selection == nil)
        #expect(keys.source.actions.isEmpty)
    }

    // MARK: - The pager (REF-KEYBOARD-005)

    @Test("ECSBPager：只有 Return 和 Enter 调 -performAction:；抬起总是 NO")
    func pagerKeys() {
        let keys = KeyGrid([35])
        for (name, event, _) in keptKeys {
            keys.reset()
            let character = Int64(event().keyData)
            let performs = character == 0x0D || character == 0x03
            #expect(!keys.pager.keyDown(event()), "\(name)")
            #expect(keys.pager.log == (performs ? ["pager keyDown NO", "pager performAction NO"] : ["pager keyDown NO"]),
                    "\(name)")
            #expect(!keys.pager.keyUp(key(character, down: false)), "\(name)")
        }
    }

    @Test("回车：选中的应用交给 handler 的 -performActionForItem:withEvent:sender:，参数是模型项、按键事件和 pager；返回 NO")
    func performAction() throws {
        let keys = KeyGrid([35])
        keys.select(0, 12)
        for character in [KeyCharacter.return, KeyCharacter.enter] {
            keys.reset()
            let event = key(character)
            #expect(!keys.pager.keyDown(event))
            let action = try #require(keys.source.actions.first)
            #expect(keys.source.actions.count == 1)
            #expect(action.item === keys.item(0, 12).clientItem)
            #expect(action.event === event)
            #expect(action.sender === keys.pager)
        }
        keys.show(0)
        #expect(!keys.pager.keyDown(key(KeyCharacter.return)))
        #expect(!keys.pager.performAction(nil))
        #expect(keys.source.actions.isEmpty)
    }

    @Test("回车：选中文件夹时返回 YES，不交给 handler（打开文件夹在阶段 5）")
    func performActionOnFolder() {
        let scene = SceneGrid()
        let recorder = KeyGridSource(counts: [])
        let pager = scene.grid.pager
        pager.handler = recorder
        defer {
            pager.selectedItem = nil
            pager.handler = scene.source
        }
        let folder = scene.page.item.items![9] as! ECSBItem
        #expect(folder is ECSBGroupItem)
        pager.selectedItem = folder
        #expect(pager.keyDown(key(KeyCharacter.return)))
        #expect(pager.performAction(nil))
        #expect(recorder.actions.isEmpty)
    }

    // MARK: - ECSBSpringboard and Springboard (REF-KEYBOARD-001)

    @Test("ECSBSpringboard：先给 ECSBLayer，它返回 NO 再给 ECSBPager；抬起相同")
    func springboardKeys() {
        let keys = KeyGrid([35])
        for (name, event, _) in keptKeys {
            keys.reset()
            let character = Int64(event().keyData)
            let performs = character == 0x0D || character == 0x03
            #expect(!keys.grid.keyDown(event()), "\(name)")
            #expect(keys.pager.log == ["layer keyDown NO", "pager keyDown NO"] + (performs ? ["pager performAction NO"] : []),
                    "\(name)")
            keys.reset()
            #expect(!keys.grid.keyUp(key(character, down: false)), "\(name)")
            #expect(keys.pager.log == ["layer keyUp NO", "pager keyUp NO"], "\(name)")
        }
    }

    @Test("Springboard：方向键、Home、End、翻页键换成导航类型交给 ECSBSpringboard；Tab、字母、空格不导航；总是返回 YES")
    func controllerKeys() {
        let keys = KeyGrid([35, 35, 10])
        let controller = makeController(keys)
        let routes: [(name: String, event: ECEvent, navigation: String?)] = [
            ("Up", key(KeyCharacter.up), "pager navigate 0 YES"),
            ("Down", key(KeyCharacter.down), "pager navigate 1 YES"),
            ("Left", key(KeyCharacter.left), "pager navigate 2 YES"),
            ("Right", key(KeyCharacter.right), "pager navigate 3 YES"),
            ("Home", key(KeyCharacter.home), "pager navigate 6 NO"),
            ("End", key(KeyCharacter.end), "pager navigate 7 NO"),
            ("Page Up", key(KeyCharacter.pageUp), "pager navigate 8 NO"),
            ("Page Down", key(KeyCharacter.pageDown), "pager navigate 9 NO"),
            ("Tab", key(KeyCharacter.tab), nil),
            ("a", key(KeyCharacter.a), nil),
            ("Space", key(KeyCharacter.space), nil),
        ]
        for (name, event, navigation) in routes {
            keys.show(0)
            #expect(controller.keyDown(event), "\(name)")
            #expect(keys.pager.log == ["layer keyDown NO", "pager keyDown NO"] + (navigation.map { [$0] } ?? []), "\(name)")
            #expect(keys.pager.currentPageIndex == 0, "\(name)")
            #expect((keys.selection != nil) == (navigation?.hasSuffix("YES") == true), "\(name)")
        }
        // Home, End and the page keys leave a selection and the page as they are.
        keys.select(0, 28)
        for character in [KeyCharacter.home, KeyCharacter.end, KeyCharacter.pageUp, KeyCharacter.pageDown] {
            #expect(controller.keyDown(key(character)))
        }
        #expect(keys.selection == [0, 28])
        #expect(keys.pager.currentPageIndex == 0)
        #expect(controller.reasons.isEmpty)
        #expect(keys.source.actions.isEmpty)
    }

    @Test("Springboard：Cmd-→ 经 ECSBLayer、ECSBPager 到导航，换页")
    func controllerCommandRight() {
        let keys = KeyGrid([35, 35, 10])
        let controller = makeController(keys)
        #expect(controller.keyDown(key(KeyCharacter.right)))
        #expect(controller.keyDown(key(KeyCharacter.right, command: true)))
        #expect(keys.pager.log == ["layer keyDown NO", "pager keyDown NO", "pager navigate 3 YES",
                                   "layer keyDown NO", "pager keyDown NO", "pager navigate 3 YES", "setCurrentPageIndex 1"])
        #expect(keys.pager.currentPageIndex == 1)
        #expect(keys.selection == [1, 0])
    }

    @Test("Springboard：不可见时导航键不导航")
    func controllerHidden() {
        let keys = KeyGrid([35, 35, 10])
        let controller = makeController(keys)
        controller._visible = false
        for character in [KeyCharacter.up, KeyCharacter.down, KeyCharacter.left, KeyCharacter.right, KeyCharacter.home,
                          KeyCharacter.end, KeyCharacter.pageUp, KeyCharacter.pageDown] {
            keys.reset()
            #expect(controller.keyDown(key(character, command: true)))
            #expect(keys.pager.log == ["layer keyDown NO", "pager keyDown NO"])
        }
        #expect(keys.selection == nil)
        #expect(keys.pager.currentPageIndex == 0)
    }

    @Test("Springboard：有选中项时回车启动，没有选中项时什么也不做，都不关闭；Esc 关闭")
    func controllerReturnAndEscape() throws {
        let keys = KeyGrid([35, 35, 10])
        let controller = makeController(keys)
        #expect(controller.keyDown(key(KeyCharacter.return)))
        #expect(keys.pager.log == ["layer keyDown NO", "pager keyDown NO", "pager performAction NO"])
        #expect(keys.source.actions.isEmpty)
        keys.select(0, 3)
        for character in [KeyCharacter.return, KeyCharacter.enter] {
            keys.reset()
            let event = key(character)
            #expect(controller.keyDown(event))
            #expect(keys.pager.log == ["layer keyDown NO", "pager keyDown NO", "pager performAction NO"])
            let action = try #require(keys.source.actions.first)
            #expect(action.item === keys.item(0, 3).clientItem && action.event === event && action.sender === keys.pager)
        }
        #expect(controller.reasons.isEmpty)
        keys.reset()
        #expect(controller.keyDown(key(KeyCharacter.escape)))
        #expect(keys.pager.log == ["layer keyDown NO", "pager keyDown NO"])
        #expect(controller.reasons == ["perform cancel while visible"])
        #expect(keys.source.actions.isEmpty)
    }

    @Test("Springboard：编辑状态下 Return 和 Enter 退出编辑状态，选中的应用照样启动")
    func controllerReturnInEditMode() {
        let keys = KeyGrid([35])
        let controller = makeController(keys)
        for character in [KeyCharacter.return, KeyCharacter.enter] {
            controller.editing = true
            #expect(controller.keyDown(key(character)))
            #expect(!controller.editing)
        }
        keys.select(0, 0)
        controller.editing = true
        #expect(controller.keyDown(key(KeyCharacter.return)))
        #expect(!controller.editing)
        #expect(keys.source.actions.count == 1)
        controller.editing = true
        #expect(controller.keyDown(key(KeyCharacter.escape)))
        #expect(controller.editing)
        controller.editing = false
    }

    @Test("Springboard：抬起先给 ECSBSpringboard，返回 NO")
    func controllerKeyUp() {
        let keys = KeyGrid([35])
        let controller = makeController(keys)
        for character in [KeyCharacter.return, KeyCharacter.right, KeyCharacter.a] {
            keys.reset()
            #expect(!controller.keyUp(key(character, down: false)))
            #expect(keys.pager.log == ["layer keyUp NO", "pager keyUp NO"])
        }
    }
}

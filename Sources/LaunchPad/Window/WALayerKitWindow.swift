import AppKit
import LaunchPadPrivate

/// A window whose content is a layer tree, as the original's `WALayerKitWindow` (REF-ARCH-008).
/// Its root `layer` is shown by two windows (REF-DEV-003): the main window, below the Dock, hosts
/// the tree itself; the strip over the menu bar hosts a copy of it that this class keeps up to date
/// (springboard-shell design decision 3). Showing one tree in both windows through `CALayerHost`
/// was not reliable: the window server stopped updating one of them.
@MainActor
@objc(WALayerKitWindow)
final class WALayerKitWindow: WAWindow {
    @objc let layer: CALayer

    /// The layer the strip window's view hosts; the copy of `layer` is its only sublayer.
    let stripLayer = CALayer()
    /// Copy of each layer of the tree, by the layer it copies.
    var copies: [ObjectIdentifier: CALayer] = [:]
    var observations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]
    /// Whether a sync is registered for the current transaction's commit.
    var copySyncScheduled = false
    /// The AppKit frames the two windows were last given.
    var appKitFrames: (main: NSRect, strip: NSRect) = (.zero, .zero)

    /// The tag bits `WALayerKitWindow` adds to every window it creates (REF-ARCH-008).
    static let addedTags: UInt64 = 0x1000 | 0x80_0000 | 0x80_0000_0000_0000

    @objc(initWithFrame:connection:display:tags:level:)
    init(frame: CGRect, connection: UInt32, display: UInt32, tags: UInt64, level: Int32) {
        layer = CALayer()
        super.init()
        _frame = frame
        let (main, strip) = Self.windowFrames(for: frame)
        appKitFrames = (Self.appKitRect(main), Self.appKitRect(strip))
        // REF-DEV-003: the main window stays below the Dock's window, at level 20.
        mainWindow = LaunchPadWindow(contentRect: appKitFrames.main, hosting: layer, level: 19)
        stripWindow = LaunchPadWindow(contentRect: appKitFrames.strip, hosting: stripLayer, level: level)
        var allTags = tags | Self.addedTags
        for window in [mainWindow, stripWindow] {
            guard let window else { continue }
            CGSSetWindowTags(Int32(bitPattern: connection), CGSWindowID(window.windowNumber), &allTags, 0x40)
        }
        syncCopy()
    }

    /// Sets the frame (global coordinates) of both windows. Does nothing when it is unchanged and both
    /// windows are still where it put them: unlike the original's window-server window, AppKit can move
    /// them by itself (the strip has been found below the menu bar's area while ordered out).
    @objc(setFrame:)
    func setFrame(_ frame: CGRect) {
        guard frame != _frame || mainWindow?.frame != appKitFrames.main || stripWindow?.frame != appKitFrames.strip
        else { return }
        _frame = frame
        let (main, strip) = Self.windowFrames(for: frame)
        appKitFrames = (Self.appKitRect(main), Self.appKitRect(strip))
        mainWindow?.setFrame(appKitFrames.main, display: false)
        stripWindow?.setFrame(appKitFrames.strip, display: false)
        copyNeedsSync()
    }

    /// A rectangle in global coordinates (origin at the top left) in the window's coordinates (origin
    /// at the bottom left), as the original converts it (research paper §3.1).
    @objc(convertRectFromGlobal:)
    func convertRectFromGlobal(_ rect: CGRect) -> CGRect {
        let frame = frame()
        return CGRect(x: rect.minX - frame.minX, y: frame.height - (rect.minY - frame.minY) - rect.height,
                      width: rect.width, height: rect.height)
    }

    // MARK: - Window frames

    /// The main window's and the strip's frames in global coordinates: the strip is the menu bar's
    /// area at the top of `frame`, the main window the rest (REF-DEV-003).
    static func windowFrames(for frame: CGRect) -> (main: CGRect, strip: CGRect) {
        let height = min(menuBarHeight(in: frame), frame.height)
        let strip = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: height)
        let main = CGRect(x: frame.minX, y: frame.minY + height, width: frame.width, height: frame.height - height)
        return (main, strip)
    }

    /// The height of the window server's menu bar window on the display at `frame`.
    static func menuBarHeight(in frame: CGRect) -> CGFloat {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in windows where info[kCGWindowName as String] as? String == "Menubar" {
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  frame.contains(CGPoint(x: rect.midX, y: rect.midY)) else { continue }
            return rect.height
        }
        return 0
    }

    /// Converts global coordinates (origin at the top left of the main display, y down) to AppKit's
    /// screen coordinates (origin at the bottom left of the main display, y up).
    static func appKitRect(_ rect: CGRect) -> NSRect {
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        return NSRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: - The strip's copy of the tree

    /// No implicit animation on the copies: the animations of the tree are copied explicitly.
    static let noActions: [String: any CAAction] = {
        let keys = ["bounds", "position", "anchorPoint", "anchorPointZ", "zPosition", "transform",
                    "sublayerTransform", "geometryFlipped", "opacity", "hidden", "contents", "contentsRect",
                    "contentsCenter", "contentsGravity", "contentsScale", "masksToBounds", "doubleSided",
                    "cornerRadius", "backgroundColor", "borderWidth", "borderColor", "shadowOpacity",
                    "shadowRadius", "shadowOffset", "shadowColor", "shadowPath", "filters", "backgroundFilters",
                    "compositingFilter", "shouldRasterize", "rasterizationScale", "mask", "sublayers",
                    kCAOnOrderIn, kCAOnOrderOut]
        return Dictionary(uniqueKeysWithValues: keys.map { ($0, NSNull() as any CAAction) })
    }()

    /// Registers a sync of the copy for the commit of the current transaction, before it is
    /// committed, so that the copy's changes and animations go into the same commit as the tree's.
    func copyNeedsSync() {
        guard !copySyncScheduled else { return }
        copySyncScheduled = true
        let target = UncheckedBox(WeakWindow(value: self))
        CATransaction.addCommitHandler({
            MainActor.assumeIsolated { target.value.value?.syncCopy() }
        }, forPhase: 1)
    }

    /// Brings the copy of the tree up to date: structure, the properties that affect drawing, and
    /// the animations.
    func syncCopy() {
        copySyncScheduled = false
        var visited = Set<ObjectIdentifier>()
        let rootCopy = copy(of: layer)
        sync(layer, into: rootCopy, visited: &visited)
        // The copy of the root sits where the tree is drawn on the display: the strip shows the top
        // band of it.
        if let main = mainWindow?.frame, let strip = stripWindow?.frame {
            rootCopy.position = CGPoint(x: layer.position.x + main.minX - strip.minX,
                                        y: layer.position.y + main.minY - strip.minY)
        }
        if stripLayer.sublayers?.first !== rootCopy {
            stripLayer.actions = Self.noActions
            stripLayer.sublayers = [rootCopy]
        }
        for id in Array(copies.keys) where !visited.contains(id) {
            copies[id] = nil
            observations[id] = nil
        }
    }

    /// A plain `CALayer` for every layer: the grid's layer classes have no `-init` to make a copy of
    /// their own class with, and no text is drawn in the strip's area yet.
    func copy(of source: CALayer) -> CALayer {
        let id = ObjectIdentifier(source)
        if let copy = copies[id] { return copy }
        let copy = CALayer()
        copy.actions = Self.noActions
        copies[id] = copy
        observations[id] = observe(source)
        return copy
    }

    func sync(_ source: CALayer, into copy: CALayer, visited: inout Set<ObjectIdentifier>) {
        visited.insert(ObjectIdentifier(source))
        copy.bounds = source.bounds
        copy.position = source.position
        copy.anchorPoint = source.anchorPoint
        copy.anchorPointZ = source.anchorPointZ
        copy.zPosition = source.zPosition
        copy.transform = source.transform
        copy.sublayerTransform = source.sublayerTransform
        copy.isGeometryFlipped = source.isGeometryFlipped
        copy.opacity = source.opacity
        copy.isHidden = source.isHidden
        copy.contents = source.contents
        copy.contentsRect = source.contentsRect
        copy.contentsCenter = source.contentsCenter
        copy.contentsGravity = source.contentsGravity
        copy.contentsScale = source.contentsScale
        copy.masksToBounds = source.masksToBounds
        copy.isDoubleSided = source.isDoubleSided
        copy.cornerRadius = source.cornerRadius
        copy.backgroundColor = source.backgroundColor
        copy.borderWidth = source.borderWidth
        copy.borderColor = source.borderColor
        copy.shadowOpacity = source.shadowOpacity
        copy.shadowRadius = source.shadowRadius
        copy.shadowOffset = source.shadowOffset
        copy.shadowColor = source.shadowColor
        copy.shadowPath = source.shadowPath
        copy.filters = source.filters?.map { ($0 as? NSCopying)?.copy() ?? $0 }
        copy.backgroundFilters = source.backgroundFilters?.map { ($0 as? NSCopying)?.copy() ?? $0 }
        copy.compositingFilter = source.compositingFilter
        copy.shouldRasterize = source.shouldRasterize
        copy.rasterizationScale = source.rasterizationScale
        copy.allowsGroupOpacity = source.allowsGroupOpacity
        copy.allowsEdgeAntialiasing = source.allowsEdgeAntialiasing
        copy.magnificationFilter = source.magnificationFilter
        copy.minificationFilter = source.minificationFilter
        if let mask = source.mask {
            let maskCopy = self.copy(of: mask)
            sync(mask, into: maskCopy, visited: &visited)
            copy.mask = maskCopy
        } else {
            copy.mask = nil
        }

        let sublayers = source.sublayers ?? []
        let sublayerCopies = sublayers.map { self.copy(of: $0) }
        if (copy.sublayers ?? []).map(ObjectIdentifier.init) != sublayerCopies.map(ObjectIdentifier.init) {
            copy.sublayers = sublayerCopies.isEmpty ? nil : sublayerCopies
        }
        for (sublayer, sublayerCopy) in zip(sublayers, sublayerCopies) {
            sync(sublayer, into: sublayerCopy, visited: &visited)
        }

        // An animation added in this transaction has a begin time of 0 until the commit sets it, so
        // the copy added now starts in the same commit. One already running keeps its begin time.
        let keys = source.animationKeys() ?? []
        for key in keys {
            guard let animation = source.animation(forKey: key) else { continue }
            if animation.beginTime != 0, copy.animation(forKey: key)?.beginTime == animation.beginTime { continue }
            copy.add(animation, forKey: key)
        }
        for key in copy.animationKeys() ?? [] where !keys.contains(key) {
            copy.removeAnimation(forKey: key)
        }
    }

    /// Observes the properties of `source` that the copy takes, so that any change schedules a sync.
    func observe(_ source: CALayer) -> [NSKeyValueObservation] {
        let target = UncheckedBox(WeakWindow(value: self))
        func watch<Value>(_ keyPath: KeyPath<CALayer, Value>) -> NSKeyValueObservation {
            source.observe(keyPath, options: []) { _, _ in
                MainActor.assumeIsolated { target.value.value?.copyNeedsSync() }
            }
        }
        return [
            watch(\.bounds), watch(\.position), watch(\.anchorPoint), watch(\.zPosition), watch(\.transform),
            watch(\.sublayerTransform), watch(\.isGeometryFlipped), watch(\.opacity), watch(\.isHidden),
            watch(\.contents), watch(\.contentsRect), watch(\.contentsGravity), watch(\.contentsScale),
            watch(\.masksToBounds), watch(\.cornerRadius), watch(\.backgroundColor), watch(\.filters),
            watch(\.shouldRasterize), watch(\.rasterizationScale), watch(\.mask), watch(\.sublayers),
        ]
    }
}

/// A weak reference, for the observation and commit-handler blocks.
struct WeakWindow {
    weak var value: WALayerKitWindow?
}

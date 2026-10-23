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
    /// A layer of the tree whose content is opaque wherever the strip shows it: the overlay's
    /// background container. Its copy gets an opaque background color, which that content covers. On
    /// macOS 27.0.1, without a layer with a background color in the strip, the window server stops
    /// showing the strip at the next change of the menu bar's content, while the strip shows the
    /// blurred background (REF-DEV-003).
    weak var opaqueLayer: CALayer?

    /// The tag bits `WALayerKitWindow` adds to every window it creates (REF-ARCH-008).
    static let addedTags: UInt64 = 0x1000 | 0x80_0000 | 0x80_0000_0000_0000

    @objc(initWithFrame:connection:display:tags:level:)
    init(frame: CGRect, connection: UInt32, display: UInt32, tags: UInt64, level: Int32) {
        layer = CALayer()
        super.init()
        _frame = frame
        let (main, strip) = Self.windowFrames(for: frame)
        // REF-DEV-003: the main window stays below the Dock's window, at level 20.
        mainWindow = LaunchPadWindow(contentRect: Self.appKitRect(main), hosting: layer, level: 19)
        stripWindow = LaunchPadWindow(contentRect: Self.appKitRect(strip), hosting: stripLayer, level: level)
        var allTags = tags | Self.addedTags
        for window in [mainWindow, stripWindow] {
            guard let window else { continue }
            CGSSetWindowTags(Int32(bitPattern: connection), CGSWindowID(window.windowNumber), &allTags, 0x40)
        }
        syncCopy()
    }

    /// Sets the frame (global coordinates) of both windows. Does nothing when it is unchanged and both
    /// windows are at the frames the active space's menu bar now gives: unlike the original's
    /// window-server window, AppKit can move them by itself (the strip has been found below the menu
    /// bar's area while ordered out), and the menu bar's height may not have been known when the frames
    /// were last set (at login the strip was left 0 high).
    @objc(setFrame:)
    func setFrame(_ frame: CGRect) {
        let (main, strip) = Self.windowFrames(for: frame)
        let frames = (main: Self.appKitRect(main), strip: Self.appKitRect(strip))
        guard frame != _frame || mainWindow?.frame != frames.main || stripWindow?.frame != frames.strip
        else { return }
        _frame = frame
        mainWindow?.setFrame(frames.main, display: false)
        stripWindow?.setFrame(frames.strip, display: false)
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

    /// The height of the window server's menu bar window of the active space on the display at
    /// `frame`, shown or not: in a full-screen app's space the menu bar is off screen until it is
    /// shown over the strip's area.
    static func menuBarHeight(in frame: CGRect) -> CGFloat {
        let connection = CGSMainConnectionID()
        let space = NSNumber(value: CGSGetActiveSpace(connection))
        let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in windows where info[kCGWindowName as String] as? String == "Menubar" {
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.minX == frame.minX, rect.width == frame.width,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let windowSpaces = CGSCopySpacesForWindows(connection, 7, [number] as CFArray) as? [NSNumber],
                  windowSpaces.contains(space) else { continue }
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
    /// the animations. Only the layers that can reach the strip's band are copied: the rest of the
    /// tree is never shown there, and syncing all of it at every commit made the open slower than the
    /// original's.
    func syncCopy() {
        copySyncScheduled = false
        var visited = Set<ObjectIdentifier>()
        let rootCopy = copy(of: layer)
        rootCopy.bounds = layer.bounds
        rootCopy.anchorPoint = layer.anchorPoint
        rootCopy.transform = layer.transform
        rootCopy.isGeometryFlipped = layer.isGeometryFlipped
        placeRootCopy(rootCopy)
        if stripLayer.sublayers?.first !== rootCopy {
            stripLayer.actions = Self.noActions
            stripLayer.sublayers = [rootCopy]
        }
        // The strip's area in the tree's coordinates.
        let band = rootCopy.convert(stripLayer.bounds, from: stripLayer)
        sync(layer, into: rootCopy, band: band, reach: 0, visited: &visited)
        placeRootCopy(rootCopy)
        for id in Array(copies.keys) where !visited.contains(id) {
            copies[id] = nil
            observations[id] = nil
        }
    }

    /// The copy of the root sits where the tree is drawn on the display: the strip shows the top band
    /// of it.
    func placeRootCopy(_ rootCopy: CALayer) {
        if let main = mainWindow?.frame, let strip = stripWindow?.frame {
            rootCopy.position = CGPoint(x: layer.position.x + main.minX - strip.minX,
                                        y: layer.position.y + main.minY - strip.minY)
        } else {
            rootCopy.position = layer.position
        }
    }

    /// How far a point of `source`'s subtree can move from where the model puts it while its
    /// transform animations run: the largest change of scale between an animation's values and the
    /// model value, times the tree's size. The open and close zoom the main grid this way
    /// (REF-OVERLAY-001, REF-OVERLAY-004).
    func animatedReach(of source: CALayer) -> CGFloat {
        let model = source.transform
        var deviation: CGFloat = 0
        for key in source.animationKeys() ?? [] {
            guard let animation = source.animation(forKey: key) as? CABasicAnimation,
                  animation.keyPath == "transform" else { continue }
            for value in [animation.fromValue, animation.toValue] {
                guard let transform = (value as? NSValue)?.caTransform3DValue,
                      model.m11 != 0, model.m22 != 0 else { continue }
                deviation = max(deviation, abs(transform.m11 / model.m11 - 1), abs(transform.m22 / model.m22 - 1))
            }
        }
        let size = max(layer.bounds.width, layer.bounds.height)
        return deviation * size
    }

    /// Whether `source` can show in `band` (the tree's coordinates): its bounds in the tree, widened
    /// by `reach`, meet the band. A layer without a size may hold sublayers anywhere, so it counts.
    func reaches(_ source: CALayer, band: CGRect, reach: CGFloat) -> Bool {
        if source.bounds.isEmpty { return true }
        let rect = source.convert(source.bounds, to: layer)
        return rect.insetBy(dx: -reach, dy: -reach).intersects(band)
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

    func sync(_ source: CALayer, into copy: CALayer, band: CGRect, reach: CGFloat, visited: inout Set<ObjectIdentifier>) {
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
        copy.backgroundColor = source === opaqueLayer ? CGColor(gray: 0, alpha: 1) : source.backgroundColor
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
            sync(mask, into: maskCopy, band: .infinite, reach: reach, visited: &visited)
            copy.mask = maskCopy
        } else {
            copy.mask = nil
        }

        let candidates = (source.sublayers ?? []).map { ($0, reach + animatedReach(of: $0)) }
        let sublayers = candidates.filter { reaches($0.0, band: band, reach: $0.1) }
        let sublayerCopies = sublayers.map { self.copy(of: $0.0) }
        if (copy.sublayers ?? []).map(ObjectIdentifier.init) != sublayerCopies.map(ObjectIdentifier.init) {
            copy.sublayers = sublayerCopies.isEmpty ? nil : sublayerCopies
        }
        for ((sublayer, sublayerReach), sublayerCopy) in zip(sublayers, sublayerCopies) {
            sync(sublayer, into: sublayerCopy, band: band, reach: sublayerReach, visited: &visited)
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

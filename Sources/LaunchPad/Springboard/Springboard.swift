import AppKit
import CoreText
import LaunchPadPrivate
import os

/// Launchpad's controller (REF-ARCH-005, REF-ARCH-006): the window, the overlay container, the
/// background, the open and close (REF-OVERLAY-007), and the startup that connects the model to the
/// grid (REF-GRID-001). It is the grid components' data source.
@MainActor
@objc(Springboard)
class Springboard: NSObject, CALayerDelegate, ECSBDataSource {
    let window: WALayerKitWindow
    @objc let layer: CALayer
    let desktopContainerLayer: CALayer
    var desktopLayer: CALayer?
    let desktopFilters: [CAFilter]
    var openCount: UInt32 = 0
    var _visibility: Float = 0
    var _visible = false
    var windowIsOrderedOn = false
    var desktopStale = false
    var desktopLastUUID: String?
    var springboard: ECSBSpringboard!
    var iconSize: UInt = 0
    var miniIconSize: UInt = 0
    var appManager: LPAppManager?
    var appLayout: LPLayout?
    var rootPage: LPRoot?
    var startTime: CFTimeInterval = 0
    var loadingContainerLayer: CALayer?
    var loadingLayer: ECShadowTextLayer?
    var _deferLayout = false
    var scanningComplete = false

    nonisolated(unsafe) private static var scanningContext = 0

    override init() {
        layer = CALayer()
        desktopContainerLayer = CALayer()
        // REF-OVERLAY-005: the three background filters, created once.
        let blur = CAFilter(type: kCAFilterGaussianBlur)
        blur.setValue(kCFBooleanTrue, forKey: "inputHardEdges")
        blur.setValue(30, forKey: "inputRadius")
        let saturate = CAFilter(type: kCAFilterColorSaturate)
        saturate.setValue(1.8, forKey: "inputAmount")
        let matrix = CAFilter(type: kCAFilterColorMatrix)
        let values = CAColorMatrix(m11: 0.55, m12: 0, m13: 0, m14: 0, m15: 0.05292,
                                   m21: 0, m22: 0.55, m23: 0, m24: 0, m25: 0.05292,
                                   m31: 0, m32: 0, m33: 0.55, m34: 0, m35: 0.05292,
                                   m41: 0, m42: 0, m43: 0, m44: 1, m45: 0)
        matrix.setValue(NSValue(caColorMatrix: values), forKey: "inputColorMatrix")
        desktopFilters = [blur, saturate, matrix]
        let display = CGMainDisplayID()
        // REF-ARCH-008: tags 0x400 and level 20.
        window = WALayerKitWindow(frame: CGDisplayBounds(display), connection: dockGlobals.dockConnection,
                                  display: display, tags: 0x400, level: 20)
        super.init()
        layer.delegate = self
        layer.insertSublayer(desktopContainerLayer, at: 0)
        springboard = ECSBSpringboard(handler: self, numberOfRowsPerPage: springboardRows,
                                      numberOfColumnsPerPage: springboardColumns,
                                      scaleFactor: Float(Self.scaleFactor(of: display)), layoutRTL: layoutRightToLeft)
        // REF-GRID-005: read once, default 0, not clamped.
        springboard.layer.zoomStyle = Int((UserDefaults.standard.object(forKey: "springboard-zoom-style") as? NSNumber)?.int32Value ?? 0)
        layer.addSublayer(springboard.layer)
        _deferLayout = true
        let wid = window.wid()
        if wid != 0 {
            CGSSetWindowProperty(Int32(bitPattern: dockGlobals.dockConnection), wid, "kCGSWindowTitle" as CFString,
                                 NSStringFromClass(type(of: self)) as CFString)
        }
    }

    /// The display Launchpad is shown on: the Dock's in the original. Only one display is handled
    /// in this sub-phase (multiple displays are 1.6).
    @objc func display() -> UInt32 {
        CGMainDisplayID()
    }

    /// The bounds of `-display` in global coordinates (REF-ARCH-008).
    @objc func totalScreenBounds() -> CGRect {
        CGDisplayBounds(display())
    }

    @objc func containerWindow() -> WALayerKitWindow {
        window
    }

    @objc var visible: Bool { _visible }

    // MARK: - Startup (REF-GRID-001)

    /// Called once, after the controller has been created: connects the model and shows the loading
    /// indicator until the first scan has been handled.
    @objc func activate() {
        _setupApplicationSources(true)
        NotificationCenter.default.addObserver(self, selector: #selector(_desktopPictureChanged(_:)),
                                               name: NSNotification.Name("desktoppicturechanged"),
                                               object: gDesktopPictureManager)
    }

    /// Called once the rest of the startup has run: from then on the grid is laid out.
    @objc func start() {
        setDeferLayout(false)
        layout()
    }

    /// Takes the app manager, waits for its roots and for the end of the first scan. The manager's
    /// notifications (added and removed apps, App Store) are phase 6.
    @objc(_setupApplicationSources:)
    func _setupApplicationSources(_ displayLoading: Bool) {
        startTime = CACurrentMediaTime()
        appManager = LPAppManager.sharedManager()
        appManager?.roots { [self] root, _ in
            MainActor.assumeIsolated {
                guard let root else { return }
                rootPage = root
                // The root's progress is observed here too (phase 6).
                let paths = ((appManager?.sources ?? []) as NSArray).value(forKey: "path") as? [Any] ?? []
                // REF-LAYOUT-006: columns × rows on a page and in a folder.
                appLayout = LPLayout(rootPage: root, sources: paths, maxItemsPerPage: springboardRows * springboardColumns,
                                     maxItemsPerGroup: springboardRows * springboardColumns)
                if !(appManager?.sourcesStillScanning ?? false) {
                    _handleInitialSourceScanCompletion()
                }
            }
        }
        appManager?.addObserver(self, forKeyPath: "sourcesStillScanning", options: [.initial], context: &Self.scanningContext)
        if displayLoading {
            _displayLoadingLayer()
        }
    }

    override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                                           context: UnsafeMutableRawPointer?) {
        guard context == &Self.scanningContext else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        MainActor.assumeIsolated {
            // Not checking for the roots: when every source completes at once, this runs before they
            // arrive, and the roots' block runs it again (research paper §12.9).
            if keyPath == "sourcesStillScanning", !(appManager?.sourcesStillScanning ?? false), !scanningComplete {
                _handleInitialSourceScanCompletion()
                scanningComplete = true
            }
        }
    }

    /// Generates or corrects the layout (REF-LAYOUT-007), removes the loading indicator and rebuilds
    /// the grid from the layout.
    @objc func _handleInitialSourceScanCompletion() {
        let items = rootPage?.allPurgatoryItems ?? []
        if (rootPage?.children.count ?? 0) == 0 {
            _ = appLayout?.layoutForInitial(items)
        } else if let appLayout, let storage = appManager?.storage {
            appLayout.layoutItemsToNextAvailableSpace(items, withOptions: 0)
            let info = storage.dbInfo
            let excludeVersion = (info?["excludeListVersionLP"] as AnyObject?)?.integerValue ?? 0
            let gameVersion = (info?["includeAsGameListVersionLP"] as AnyObject?)?.integerValue ?? 0
            let curationVersion = (info?["curateListVersionLP"] as AnyObject?)?.integerValue ?? 0
            var gameGroup: LPGroup?
            let manager = appManager
            appLayout.fixupLayout(
                withExcludeListVersion: UInt(bitPattern: excludeVersion), includeAsGameListVersion: UInt(bitPattern: gameVersion),
                curationVersion: UInt(bitPattern: curationVersion),
                itemExcluded: { item in
                    let parent = item.parentContainer
                    if let runnable = item as? LPRunnable {
                        manager?.forgetRunnable(runnable)
                    }
                    parent?.children.remove(item)
                },
                itemIncludedAsGame: { item in
                    if gameGroup == nil {
                        gameGroup = appLayout.groupForKind(1)
                    }
                    guard let gameGroup,
                          let page = gameGroup.firstAvailablePage(withMaxCount: appLayout.maxPerGroupPage, createIfNecessary: true),
                          item.parentGroup !== gameGroup else { return }
                    let parent = item.parentContainer
                    page.children.add(item)
                    parent?.children.remove(item)
                },
                changesMade: { excludeChanged, gameChanged, curated in
                    if excludeChanged {
                        storage.setDBInfoValue(NSNumber(value: appLayout.excludeListVersion), forKey: "excludeListVersionLP")
                    }
                    if gameChanged {
                        storage.setDBInfoValue(NSNumber(value: appLayout.includeAsGameListVerison), forKey: "includeAsGameListVersionLP")
                    }
                    if curated {
                        storage.setDBInfoValue(NSNumber(value: appLayout.curationVerison), forKey: "curateListVersionLP")
                    }
                })
        }
        rootPage?.purgePurgatory()
        appManager?.storage?.markInitialSetupComplete()
        // The startup time is reported for analytics here (not done in this project); icons are
        // requested and every item observed, and the layout's blocks set (1.3.3, phase 6).
        _removeLoadingLayer()
        springboard.invalidate()
        scanningComplete = true
    }

    @objc func deferLayout() -> Bool {
        _deferLayout
    }

    @objc(setDeferLayout:)
    func setDeferLayout(_ deferLayout: Bool) {
        _deferLayout = deferLayout
    }

    /// Lays out the overlay container; places the main grid above or beside the Dock with margins
    /// worked out from the columns, rows and the Dock's thickness (REF-GRID-004); lays out the grid and
    /// the loading indicator; and keeps the icon sizes for that grid (REF-GRID-006).
    @objc func layout() {
        guard !_deferLayout else { return }
        let bounds = containerWindow().convertRectFromGlobal(totalScreenBounds())
        let disabled = disableActions()
        layer.frame = bounds
        let tileSize = dockBar.tileSize
        let distanceTop = dockBar.distanceTop
        let distanceBottom = dockBar.distanceBottom
        let orientation = dockBar.barOrientation
        let dockThickness = CGFloat((tileSize + distanceTop + distanceBottom).rounded(.up))
        // REF-GRID-004: 30 points above the bottom, or above the Dock when it is at the bottom.
        let showsDock = (self as! LPSpringboard).showsDock()
        var gridFrame = CGRect.zero
        var width: CGFloat = 0
        if !showsDock {
            gridFrame = CGRect(x: 0, y: 30, width: bounds.width, height: bounds.height - 30)
            width = bounds.width
        } else if orientation == 1 || orientation == 2 {
            gridFrame = CGRect(x: 0, y: 30, width: bounds.width, height: bounds.height - 30)
            width = bounds.width - dockThickness
        } else if orientation == 0 {
            gridFrame = CGRect(x: 0, y: dockThickness + 30, width: bounds.width, height: bounds.height - (dockThickness + 30))
            width = bounds.width
        }
        let gridLayer = springboard.layer
        let transform = gridLayer.transform
        let identity = CATransform3DEqualToTransform(transform, CATransform3DIdentity)
        if !identity {
            gridLayer.transform = CATransform3DIdentity
        }
        gridLayer.frame = gridFrame
        if !identity {
            gridLayer.transform = transform
        }
        // REF-GRID-004: a column unit from the width, the room left above the rows, and the margins.
        let unit = (width / CGFloat(springboardColumns * 2 + 1)).rounded(.down)
        let room = (gridFrame.height - CGFloat(springboardRows) * (unit + 40)).rounded(.down)
        let side = max((unit * 0.5).rounded(.down), 90)
        let top = max((room * 0.15).rounded(.down), 35)
        let bottom = max((room * 0.25).rounded(.down), 35)
        if showsDock {
            springboard.leftMargin = orientation == 1 ? side + dockThickness : side
            springboard.rightMargin = orientation == 2 ? side + dockThickness : side
        } else {
            springboard.leftMargin = side
            springboard.rightMargin = side
        }
        springboard.topMargin = top
        springboard.bottomMargin = bottom
        springboard.layout()
        if let loadingLayer, loadingLayer.superlayer != nil, let loadingContainerLayer {
            // REF-GRID-002: centered, x truncated, y and size rounded up.
            let size = loadingLayer.preferredFrameSize()
            loadingContainerLayer.frame = CGRect(x: CGFloat(Int32(bounds.minX + bounds.width * 0.5 - size.width * 0.5)),
                                                 y: (bounds.height * 0.5 - size.height * 0.5).rounded(.up),
                                                 width: size.width.rounded(.up), height: size.height.rounded(.up))
            loadingLayer.frame = loadingContainerLayer.bounds
        }
        // REF-GRID-006: the sides without the Dock; at most 512 and 128.
        var newIconSize: UInt = 128
        var newMiniIconSize: UInt = 32
        ECSBSpringboard.calculateIconSize(&newIconSize, miniIconSize: &newMiniIconSize, forBounds: gridFrame,
                                          andScaleFactor: Float(Self.scaleFactor(of: display())), usingLeftMargin: side,
                                          rightMargin: side, topMargin: top, bottomMargin: bottom,
                                          zoomStyle: gridLayer.zoomStyle, zoomFactor: getZoomFactorFromPrefs(),
                                          withNumberOfRows: springboardRows, andColumns: springboardColumns)
        newIconSize = min(newIconSize, 512)
        newMiniIconSize = min(newMiniIconSize, 128)
        if disabled {
            CATransaction.setDisableActions(false)
        }
        // Telling the grid that the sizes changed comes with the icons (1.3.3).
        if iconSize != newIconSize || miniIconSize != newMiniIconSize {
            iconSize = newIconSize
            miniIconSize = newMiniIconSize
        }
    }

    /// Not a preference: by the display's width, a little less when the Dock is at a side
    /// (REF-GRID-005).
    @objc func getZoomFactorFromPrefs() -> CGFloat {
        let width = totalScreenBounds().width
        let orientation = dockBar.barOrientation
        // REF-GRID-005
        var factor: CGFloat = 0
        if width > 1920 {
            factor = 0.6
        } else if width > 1680 {
            factor = 0.3
        } else if width > 1440 {
            factor = 0.2
        }
        if factor > 0.1, orientation != 0 {
            factor -= 0.1
        }
        return factor
    }

    // MARK: - Loading indicator (REF-GRID-001, REF-GRID-002)

    /// Shown at the end of the overlay container instead of the grid until the first scan has been
    /// handled.
    @objc func _displayLoadingLayer() {
        guard loadingLayer == nil else { return }
        // REF-GRID-002: UI font type 103 (not a public type), 60 points.
        let font = CTFontCreateUIFontForLanguage(CTFontUIFontType(rawValue: 103)!, 60, nil)
        let container = CALayer()
        loadingContainerLayer = container
        container.allowsGroupBlending = false
        layer.addSublayer(container)
        let text = ECShadowTextLayer()
        loadingLayer = text
        text.string = launchPadBundle.localizedString(forKey: "LAUNCH_PAD_LOADING", value: "", table: nil)
        // REF-GRID-002
        text.fontSize = 60
        text.foregroundColor = CGColor(gray: 52.0 / 255.0, alpha: 1)
        text.compositingFilter = kCAFilterPlusL
        text.textShadowColor = CGColor(gray: 0, alpha: 0.2)
        text.textShadowOffset = CGSize(width: 0, height: -1)
        text.textShadowBlur = 2
        text.contentsScale = Self.scaleFactor(of: display())
        if let font {
            text.font = font
        }
        springboard.layer.isHidden = true
        container.addSublayer(text)
        layout()
    }

    /// Shows the grid and fades the indicator out in a transaction of its own; when it completes both
    /// layers are removed (REF-GRID-001).
    @objc func _removeLoadingLayer() {
        guard let loadingLayer else { return }
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                let disabled = disableActions()
                self.loadingLayer?.removeFromSuperlayer()
                self.loadingContainerLayer?.removeFromSuperlayer()
                self.loadingLayer = nil
                self.loadingContainerLayer = nil
                if disabled {
                    CATransaction.setDisableActions(false)
                }
            }
        }
        springboard.layer.isHidden = false
        loadingLayer.opacity = 0
        CATransaction.commit()
    }

    // MARK: - ECSBDataSource

    /// `items` and `kind`, the keys the item tree is built from (research paper §6.1). The other keys
    /// (icons, titles, progress, status) and the search pages come with later sub-phases.
    func value(forKey key: String, ofItem item: AnyObject?, withInfo info: AnyObject?) -> AnyObject? {
        guard let item else {
            return key == "items" ? rootPage?.children : nil
        }
        switch key {
        case "items":
            return (item as? LPItemContainer)?.children
        case "kind":
            if item is LPPage {
                return "page" as NSString
            }
            return (item is LPGroup ? "group" : "item") as NSString
        default:
            return nil
        }
    }

    // MARK: - Open and close (REF-OVERLAY-007)

    @objc(setVisible:reason:)
    func setVisible(_ visible: Bool, reason: String?) {
        // REF-OVERLAY-008: slow motion only when allowed and Shift is down.
        let slow = dockGlobals.slowMotionAllowed && ECModalEventController.shiftKeyDown()
        setVisible(visible, slow: slow, forGaming: false, reason: reason)
    }

    @objc(setVisible:slow:forGaming:reason:)
    func setVisible(_ visible: Bool, slow: Bool, forGaming: Bool, reason: String?) {
        Logger().info("Launchpad changing to \(visible ? "visible" : "NOT visible") for \(reason ?? "(null)")")
        guard _visible != visible else { return }
        if visible {
            // REF-DEV-007: the conditions that refuse an open, as far as they can be read.
            guard !spaces.anySwitchingOccurring, dragController.currentDragContents & 0x10 == 0 else { return }
            if wvExpose.mode != 0 {
                wvExpose.exit()
            }
        }
        _visible = visible
        if visible {
            _deferLayout = false
            // Icon caching, the display check and the item contents come here too (1.3.3, 1.6).
            springboard.zoomFactor = getZoomFactorFromPrefs()  // REF-GRID-005
            layout()
        }
        _enterExitAnimation(visible, slow: slow)
    }

    @objc(_enterExitAnimation:slow:)
    func _enterExitAnimation(_ enter: Bool, slow: Bool) {
        if enter {
            prepareForEnterAnimation()
            performEnterAnimation(slow)
        } else {
            performExitAnimation(slow)
        }
    }

    @objc func prepareForEnterAnimation() {
        let connection = Int32(bitPattern: dockGlobals.dockConnection)
        if self is LPSpringboard {
            // REF-OVERLAY-006: above the menu bar. The Dock bar's window cannot be raised to 29 from
            // another process (REF-DEV-003).
            CGSSetWindowLevel(connection, containerWindow().wid(), 27)
        }
        if dockGlobals.externalMenuIsUp {
            CFNotificationCenterPostNotification(CFNotificationCenterGetDistributedCenter(),
                                                 CFNotificationName("com.apple.HIToolbox.cancelMenuTrackingNotification" as CFString),
                                                 nil, nil, true)
        }
        CPSStealKeyFocusOnConnection(connection, 0x480)
        desktopLayer?.removeFromSuperlayer()
        let desktopLayer = _newDesktopLayer()
        self.desktopLayer = desktopLayer
        let disabled = disableActions()
        _applyDesktopFilters()
        let bounds = CGDisplayBounds(display())
        containerWindow().layer.insertSublayer(layer, at: 0)
        desktopContainerLayer.insertSublayer(desktopLayer, at: 0)
        desktopContainerLayer.frame = CGRect(origin: .zero, size: bounds.size)
        layer.opacity = 0
        if disabled {
            CATransaction.setDisableActions(false)
        }
        CATransaction.flush()
    }

    @objc(performEnterAnimation:)
    func performEnterAnimation(_ slow: Bool) {
        CGSSetDisplayAcceleratorBoost(display(), 0)
        openCount += 1
        CATransaction.setAnimationDuration(Self.animationDuration(slow: slow, key: "springboard-show-duration"))
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))  // REF-OVERLAY-001
        CATransaction.begin()
        layer.opacity = 1  // REF-OVERLAY-001
        CATransaction.commit()
        WAWindow.setSafeApertureOverride(0, force: false)  // REF-DEV-011
        CoreCursorSet(Int32(bitPattern: dockGlobals.dockConnection), 0)  // REF-DEV-006
    }

    @objc(performExitAnimation:)
    func performExitAnimation(_ slow: Bool) {
        CGSSetDisplayAcceleratorBoost(display(), 0)
        CATransaction.setAnimationDuration(Self.animationDuration(slow: slow, key: "springboard-hide-duration"))
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))  // REF-OVERLAY-004
        let count = openCount
        let closingDesktopLayer = UncheckedBox(desktopLayer)
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                self._cleanupAfterExitAnimation(closingDesktopLayer.value, openCount: count)
            }
        }
        layer.opacity = 0  // REF-OVERLAY-004
        CATransaction.commit()
        WAWindow.setSafeApertureOverride(1, force: false)  // REF-DEV-011
        _cleanupBeforeExitAnimation()
        desktopLayer = nil
    }

    @objc func _cleanupBeforeExitAnimation() {
        CPSReleaseKeyFocusOnConnection(Int32(bitPattern: dockGlobals.dockConnection))
    }

    @objc(_cleanupAfterExitAnimation:openCount:)
    func _cleanupAfterExitAnimation(_ desktopLayer: CALayer?, openCount: UInt32) {
        if openCount == self.openCount, self is LPSpringboard {
            // REF-OVERLAY-006; the Dock bar's window was not raised (REF-DEV-003).
            CGSSetWindowLevel(Int32(bitPattern: dockGlobals.dockConnection), containerWindow().wid(), 20)
        }
        let disabled = disableActions()
        if !_visible {
            layer.removeFromSuperlayer()
        }
        desktopLayer?.removeFromSuperlayer()
        if disabled {
            CATransaction.setDisableActions(false)
        }
    }

    /// Orders the window on or off at once, in a window-server transaction of its own
    /// (REF-OVERLAY-007, REF-DEV-014).
    @objc(orderWindowOn:)
    func orderWindowOn(_ on: Bool) {
        windowIsOrderedOn = on
        guard let transaction = SLSTransactionCreate(Int32(bitPattern: dockGlobals.dockConnection)) else { return }
        window.orderImmediate(on ? 1 : 0, otherWindow: 0, with: OpaquePointer(Unmanaged.passUnretained(transaction).toOpaque()))
        SLSTransactionCommit(transaction, 0)
    }

    // MARK: - Background (REF-OVERLAY-003, REF-OVERLAY-005)

    /// The wallpaper changed on a display's space. Nothing posts this notification, in the original
    /// as here (research paper §5.4.3).
    @objc(_desktopPictureChanged:)
    func _desktopPictureChanged(_ notification: Notification) {
        let display = display()
        let info = notification.userInfo
        guard (info?["did"] as? NSNumber)?.uint64Value == UInt64(display),
              let uuid = info?["uuid"] as? String,
              let current = spaces.currentSpace(forDisplay: display)?.uuid, current == uuid else { return }
        updateDesktopImages()
    }

    /// A new background layer for the current space of the display, as large as the display.
    @objc func _newDesktopLayer() -> CALayer {
        let display = display()
        let layer = gDesktopPictureManager.layer(forSpace: spaces.currentSpace(forDisplay: display), andDisplay: display)
        layer.frame = CGRect(origin: .zero, size: CGDisplayBounds(display).size)
        return layer
    }

    @objc func _applyDesktopFilters() {
        desktopContainerLayer.shouldRasterize = true
        desktopContainerLayer.rasterizationScale = Self.scaleFactor(of: display())
        desktopContainerLayer.filters = desktopFilters
    }

    /// Replaces the background with a new capture while open (REF-OVERLAY-003). While closed there is
    /// no background layer, and when one cannot be replaced now the background is marked stale.
    @objc func updateDesktopImages() {
        guard let current = desktopLayer else { return }
        guard _visible else {
            desktopStale = true
            return
        }
        let replacement = _newDesktopLayer()
        let disabled = disableActions()
        replacement.opacity = 0
        replacement.frame = current.frame
        desktopContainerLayer.addSublayer(replacement)
        if disabled {
            CATransaction.setDisableActions(false)
        }
        CATransaction.flush()
        CATransaction.begin()
        CATransaction.setAnimationDuration(2)  // REF-OVERLAY-003
        let old = UncheckedBox(current)
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                let disabled = disableActions()
                old.value.removeFromSuperlayer()
                if disabled {
                    CATransaction.setDisableActions(false)
                }
            }
        }
        replacement.opacity = 1
        desktopLayer = replacement
        CATransaction.commit()
        desktopLastUUID = spaces.currentSpace(forDisplay: display())?.uuid
        desktopStale = false
    }

    // MARK: - Helpers

    /// The open or close duration: the slow-motion duration, else the preference, else the current
    /// transaction's (REF-OVERLAY-008). A preference that is not a number counts as unset; it is used
    /// in single precision, without clamping.
    static func animationDuration(slow: Bool, key: String) -> CFTimeInterval {
        if slow {
            return 5  // REF-OVERLAY-008
        }
        let fallback = Float(CATransaction.animationDuration())
        let value = (UserDefaults.standard.object(forKey: key) as? NSNumber)?.floatValue ?? fallback
        return CFTimeInterval(value)
    }

    /// The scale factor of a display's current mode; 1 when it cannot be read or is not positive
    /// (REF-OVERLAY-005).
    static func scaleFactor(of display: UInt32) -> CGFloat {
        guard let mode = CGDisplayCopyDisplayMode(display), mode.width > 0 else { return 1 }
        let scale = CGFloat(mode.pixelWidth) / CGFloat(mode.width)
        return scale > 0 ? scale : 1
    }
}

/// Columns and rows of a page: preferences read once per process, each clamped to 2...100
/// (REF-LAYOUT-006).
@MainActor let springboardColumns = pageDimension("springboard-columns", default: 7)
@MainActor let springboardRows = pageDimension("springboard-rows", default: 5)

@MainActor
func pageDimension(_ key: String, default value: Int32) -> UInt {
    let number = (UserDefaults.standard.object(forKey: key) as? NSNumber)?.int32Value ?? value
    return number > 1 ? UInt(min(number, 100)) : 2  // REF-LAYOUT-006
}

/// Whether the layout is right to left: read once at startup, before the controller is created, and
/// passed to every grid class (REF-GRID-009).
nonisolated(unsafe) var layoutRightToLeft = false

/// The writing direction as Dock's monitor decides it (REF-GRID-009): a direction forced by
/// preference when `AppleTextDirection` is set, otherwise the system's user interface. The preferences
/// are read from `domain` for the current user on any host.
func writingDirectionIsRightToLeft(domain: CFString) -> Bool {
    func bool(_ key: String) -> Bool {
        CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool ?? false
    }
    if bool("AppleTextDirection") {
        if bool("NSForceRightToLeftWritingDirection") {
            return true
        }
        if bool("NSForceLeftToRightWritingDirection") {
            return false
        }
    }
    return SLSGetSystemUIHasRTLDirectionLegacy()
}

/// Disables implicit actions in the current transaction unless they already are; returns whether it
/// did, so the caller can enable them again.
@MainActor
func disableActions() -> Bool {
    guard !CATransaction.disableActions() else { return false }
    CATransaction.setDisableActions(true)
    return true
}

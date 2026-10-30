import os
import QuartzCore

/// The main grid's pager layer (REF-ARCH-007). It makes a page for every page item that has none and
/// drops the pages no page item refers to any more (research paper §6.2).
@MainActor
@objc(ECSBLayer)
class ECSBLayer: ECPagerLayer, ECEventHandlingDelegate {
    var _zoomFactor: CGFloat = 0.5  // REF-GRID-005
    @objc var zoomStyle = 0
    var scaleFactor: Float = 0
    var leftMouseDown = false
    /// Set by `-keyDown:` for the keys it decides on itself; the search field gets the key up of the
    /// others (REF-KEYBOARD-001).
    var keyDownHandled = false
    var mouseDragged = false

    @objc(initWithPager:scaleFactor:layoutRTL:)
    required init(pager: ECPager?, scaleFactor: Float, layoutRTL: Bool) {
        super.init(pager: pager, layoutRTL: layoutRTL)
        masksToBounds = false
        scrollLayer.masksToBounds = false
        self.scaleFactor = scaleFactor
    }

    /// Only the initializer of `ECPager`, which `ECSBPager` replaces at once, makes an `ECSBLayer`
    /// this way (research paper §6.2).
    required init(pager: ECPager?, layoutRTL: Bool) {
        super.init(pager: pager, layoutRTL: layoutRTL)
    }

    nonisolated override init(layer: Any) {
        super.init(layer: layer)
    }

    nonisolated required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// Clamped to 0…1 (REF-GRID-005).
    @objc var zoomFactor: CGFloat {
        get { _zoomFactor }
        set {
            guard _zoomFactor != newValue else { return }
            _zoomFactor = newValue < 0 ? 0 : min(newValue, 1)
        }
    }

    /// The margins widened by the zoom factor, each rounded down (REF-GRID-005).
    @objc func adjustedLeftMargin() -> CGFloat {
        (zoomFactor * (bounds.width * 0.2) + leftMargin).rounded(.down)
    }

    @objc func adjustedRightMargin() -> CGFloat {
        (zoomFactor * (bounds.width * 0.2) + rightMargin).rounded(.down)
    }

    /// Widened unless the zoom style is 0 or 2 (REF-GRID-005).
    @objc func adjustedTopMargin() -> CGFloat {
        let widened = zoomFactor * (bounds.height * 0.2) + topMargin
        return (zoomStyle & ~2 == 0 ? topMargin : widened).rounded(.down)
    }

    /// Widened for zoom styles 1 and 2 only (REF-GRID-005).
    @objc func adjustedBottomMargin() -> CGFloat {
        let widened = zoomFactor * ((bounds.height - 30) * 0.2) + bottomMargin
        return (UInt(bitPattern: zoomStyle - 1) < 2 ? widened : bottomMargin).rounded(.down)
    }

    /// As the pager layer's, then marks the new current page as recently viewed; without a pager
    /// nothing changes (REF-PAGING-001).
    @objc(setCurrentPageIndex:)
    override func setCurrentPageIndex(_ index: UInt) {
        guard let pager, !pager.disableScrolling else { return }
        let pages = pager.pages
        if index < UInt(pages.count) {
            super.setCurrentPageIndex(index)
            (pages[Int(index)] as? ECSBPage)?.recentlyViewed = true
        } else if pages.count == 0, index == 0 {
            super.setCurrentPageIndex(0)
        }
    }

    /// Makes and drops pages (REF-GRID-003), then places the scroll layer and the pages between the
    /// adjusted margins, side by side one width of this layer apart, and scrolls to the current page
    /// (REF-GRID-007).
    override func layout() {
        guard let pager, let source = pager.pagerSource else { return }
        let pages = pager.pages
        let pageItems = source.pageItems(for: pager) ?? NSArray()
        var count = pages.count
        let wanted = Int(source.numberOfPages(for: pager))
        let notchHeight = dockBar.display.notchBounds.height
        let left = adjustedLeftMargin()
        let right = adjustedRightMargin()
        let top = adjustedTopMargin()
        var bottom = adjustedBottomMargin()
        // REF-GRID-007: room for the page control when it shows.
        if pagerControlVisibility == 1 || (pagerControlVisibility == 3 && wanted == 1) {
            bottom -= 15
        }
        if count < wanted {
            for case let (index, pageItem as ECSBPageItem) in pageItems.enumerated() where pageItem.page == nil {
                guard let page = source.makePage(for: pager, at: UInt(index)), let layer = page.layer else { continue }
                pages.insert(page, at: index)
                scrollLayer.addSublayer(layer)
            }
        } else if wanted < count {
            let referenced = NSMutableSet(capacity: 0)
            for case let pageItem as ECSBPageItem in pageItems {
                if let page = pageItem.page {
                    referenced.add(page)
                }
            }
            repeat {
                count -= 1
                if let page = pages[count] as? ECPage, !referenced.contains(page) {
                    page.layer?.removeFromSuperlayer()
                    pages.removeObject(at: count)
                }
            } while wanted < count
        }
        let bounds = bounds
        // REF-GRID-007: up to 30 points below the top.
        scrollLayer.frame = CGRect(x: bounds.minX, y: bottom, width: bounds.width, height: bounds.height - 30 - bottom)
        let pageWidth = bounds.width - (left + right)
        var x = layoutRTL ? bounds.width * CGFloat(wanted) - (right + pageWidth) : left
        guard bounds == .zero || (bounds.width > 1 && bounds.height > 1) else {
            Logger().error("Layer bounds is too small to layout correctly (\(bounds.minX), \(bounds.minY)) - (\(bounds.width), \(bounds.height)).")
            return
        }
        let pageHeight = bounds.height - 30 - (notchHeight + top + bottom)
        for case let page as ECPage in pages {
            page.layer?.frame = CGRect(x: x, y: 0, width: pageWidth, height: pageHeight)
            source.layoutPage!(page, for: pager)
            x += layoutRTL ? -bounds.width : bounds.width
        }
        // Right to left, an unsigned page count less one less the current page (REF-GRID-007).
        let index = layoutRTL ? UInt(bitPattern: wanted) &+ ~currentPageIndex : currentPageIndex
        scrollLayer.scroll(to: CGPoint(x: bounds.width * CGFloat(index), y: 0))
        // REF-PAGING-003: hidden with visibility 1, or 2 or 3 and one page; otherwise while a folder is
        // shown (phase 5). Across the grid, 15 high, centered on half the bottom margin as set.
        let disabled = disableActions()
        controlLayer.isHidden = pagerControlVisibility == 1 || (pagerControlVisibility & ~1 == 2 && wanted == 1)
        let y = CGFloat(Int(bottomMargin * 0.5 - 7.5))
        controlLayer.frame = CGRect(x: 0, y: 0 <= y ? y : 0, width: bounds.width, height: 15)
        controlLayer.layout()
        if disabled {
            CATransaction.setDisableActions(false)
        }
    }

    /// The icon size and the folder's mini icon size for the main grid (REF-GRID-006): the margins
    /// widened by the zoom, 15 more at the bottom, leave the area of the cells.
    @objc(calculateIconSize:miniIconSize:forBounds:andScaleFactor:usingLeftMargin:rightMargin:topMargin:bottomMargin:zoomStyle:zoomFactor:withNumberOfRows:andColumns:)
    static func calculateIconSize(_ iconSize: UnsafeMutablePointer<UInt>, miniIconSize: UnsafeMutablePointer<UInt>,
                                  forBounds bounds: CGRect, andScaleFactor scaleFactor: Float,
                                  usingLeftMargin leftMargin: CGFloat, rightMargin: CGFloat, topMargin: CGFloat,
                                  bottomMargin: CGFloat, zoomStyle: Int, zoomFactor: CGFloat,
                                  withNumberOfRows rows: UInt, andColumns columns: UInt) {
        let height = bounds.height - 30  // REF-GRID-006
        let widening = bounds.width * 0.2 * zoomFactor
        let left = (widening + leftMargin).rounded(.down)
        let right = (widening + rightMargin).rounded(.down)
        let top = (zoomStyle & ~2 == 0 ? topMargin : bounds.height * 0.2 * zoomFactor + topMargin).rounded(.down)
        let bottom = (UInt(bitPattern: zoomStyle - 1) < 2 ? height * 0.2 * zoomFactor + bottomMargin : bottomMargin)
            .rounded(.down) - 15
        ECSBGridLayer.calculateIconSize(iconSize, miniIconSize: miniIconSize,
                                        forBounds: CGRect(x: 0, y: 0, width: bounds.width - (left + right),
                                                          height: height - (top + bottom)),
                                        andScaleFactor: scaleFactor, withNumberOfRows: rows, andColumns: columns)
    }

    // MARK: - Events (REF-OVERLAY-010)

    /// The shown folder's branch is phase 5.
    @objc(leftMouseDown:)
    override func leftMouseDown(_ event: ECEvent) -> Bool {
        mouseDragged = false
        leftMouseDown = true
        return super.leftMouseDown(event)
    }

    /// Marks the press as dragged once the pointer is 3 points from it on either axis
    /// (REF-OVERLAY-010).
    @objc(leftMouseDragged:)
    override func leftMouseDragged(_ event: ECEvent) -> Bool {
        if !mouseDragged {
            let location = event.location
            if abs(startLocation.x - location.x) >= 3 || abs(startLocation.y - location.y) >= 3 {  // REF-OVERLAY-010
                mouseDragged = true
            }
        }
        return super.leftMouseDragged(event)
    }

    /// A press that was not dragged cancels: the grid action handler passes it on to the controller
    /// (REF-OVERLAY-010). The folder conditions are phase 5.
    @objc(leftMouseUp:)
    override func leftMouseUp(_ event: ECEvent) -> Bool {
        let pressed = leftMouseDown
        leftMouseDown = false
        let handled = super.leftMouseUp(event)
        if pressed, !mouseDragged, let handler = (pager as? ECSBPager)?.gridActionHandler,
           handler.responds(to: #selector(ECSBGridActionHandling.cancelGridAction(with:sender:))) {
            handler.cancelGridAction?(with: event, sender: self)
        }
        mouseDragged = false
        return handled
    }

    // MARK: - Keys (REF-KEYBOARD-001)

    /// Decides which keys go to the search field. Tab, Command-Left and Command-Right, Left and Right,
    /// Up, Down, Return, Enter and Escape set `keyDownHandled` and return NO, so that they reach the
    /// navigation. Any other key, Home, End, Page Up and Page Down included, leaves it clear and goes
    /// to the search field, which returns YES. The search field comes with phase 3: until then an input
    /// method never composes in it, it never has focus or a search string, and the keys for it return
    /// NO.
    @objc(keyDown:)
    func keyDown(_ event: ECEvent) -> Bool {
        let key = event.keyData
        keyDownHandled = false
        // While an input method composes in the search field, the field gets every key (phase 3).
        if key == 0x09 {  // Tab (REF-KEYBOARD-001)
            // Toggles the search field's focus (phase 3).
            keyDownHandled = true
            return false
        }
        if event.commandKeyDown, key & 0xFFFE == 0xF702 {  // Command-Left, Command-Right (REF-KEYBOARD-001)
            keyDownHandled = true
            return false
        }
        // Space during a system drag opens or closes the folder under the drag or performs the item
        // under it (phases 4 and 5).
        switch key {
        case 0xF703:  // Right (REF-KEYBOARD-001)
            keyDownHandled = true
            // With a search string, as Left (phase 3).
            return false
        case 0xF702:  // Left (REF-KEYBOARD-001)
            keyDownHandled = true
            // The search field gets the key when it has focus (phase 3).
            return false
        case 0x03, 0x0D, 0x1B, 0xF700, 0xF701:  // Enter, Return, Escape, Up, Down (REF-KEYBOARD-001)
            keyDownHandled = true
            return false
        default:
            // With a drag capture the search field is made inactive and loses focus; otherwise it is
            // made active and gets the key (phase 3).
            return false
        }
    }

    /// The search field gets the key ups of the keys it got (phase 3); with a drag capture it is made
    /// inactive and loses focus instead (phase 3). So NO until then (REF-KEYBOARD-001).
    @objc(keyUp:)
    func keyUp(_ event: ECEvent) -> Bool {
        false
    }

    // MARK: - Scroll wheel and gestures (REF-PAGING-006)

    /// The pages follow the scroll wheel: the larger of its two deltas, doubled and negated when the
    /// scrolling is reversed, adds up from the scroll value of the first event. Outside a scroll gesture
    /// a timer then picks the page once the wheel stops; inside one the gesture's end does. Momentum
    /// events do nothing.
    @objc(scrollWheel:)
    func scrollWheel(_ event: ECEvent) -> Bool {
        let dx = event.deltaX
        let dy = event.deltaY
        let delta = abs(dx) > abs(dy) ? 2 * dx : 2 * dy  // REF-PAGING-006
        guard !event.isMomentum else { return true }
        let other = abs(dx) > abs(dy) ? 2 * dy : 2 * dx
        guard delta != 0 || other != 0, (pager as? ECSBPager)?.canScroll() == true else { return true }
        let layoutRTL = layoutRTL
        func follow() {
            let disabled = disableActions()
            cummulativeDelta += springboardReverseScrollGesture ? -delta : delta
            scrollValue = startScrollValue + cummulativeDelta
            if disabled {
                CATransaction.setDisableActions(false)
            }
        }
        guard !isGestureScrolling else {
            follow()
            return true
        }
        if scrollWheelTimer == nil {
            startScrollValue = scrollValue
            startLocation = event.location
            lastLocation = startLocation
            lastTime = event.time
            cummulativeDelta = 0
        }
        follow()
        scrollWheelTimer?.cancel()
        scrollWheelTimer = nil
        let shift = ECModalEventController.shiftKeyDown()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Picks the page: back to the first past its left edge; none at 0; otherwise the next page
        // when the scroll value is past the start, else the previous one, with the end of a drag's
        // unsigned arithmetic (REF-PAGING-005). No speed threshold.
        timer.setEventHandler {
            MainActor.assumeIsolated {
                self.scrollWheelTimer?.cancel()
                self.scrollWheelTimer = nil
                let value = self.scrollValue
                let count = UInt(self.pager?.pages.count ?? 0)
                let index: UInt
                if value < 0 {
                    index = layoutRTL ? count &- 1 : 0
                } else {
                    guard value > 0, count > 0 else { return }
                    let current = self.currentPageIndex
                    if layoutRTL {
                        let next = value > self.startScrollValue ? current &- 1 : current &+ 1
                        index = Int(bitPattern: next) < 0 ? 0 : next
                    } else {
                        index = min(value <= self.startScrollValue ? current &- 1 : current &+ 1, count - 1)
                    }
                }
                self.setCurrentPageIndex(index)
            }
        }
        // REF-PAGING-006: longer while Shift is down; fires once.
        timer.schedule(deadline: .now() + .nanoseconds(shift ? 375_000_000 : 75_000_000), repeating: .never,
                       leeway: .nanoseconds(0))
        timer.resume()
        scrollWheelTimer = timer
        return true
    }

    /// A scroll gesture's beginning stops the scroll wheel's timer and records the start; its end picks
    /// the page by the average speed of the pages over the whole gesture, as the end of a drag does
    /// (REF-PAGING-005). A navigation gesture goes to the next or the previous page. The shown folder's
    /// case is phase 5.
    @objc(gesture:)
    func gesture(_ event: ECEvent) -> Bool {
        guard let pager = pager as? ECSBPager, pager.canScroll() else { return true }
        let layoutRTL = layoutRTL
        switch event.gestureType {
        case 6:  // REF-PAGING-006: scroll
            guard pager.eventHandler?.dragCapture == nil else { return true }
            let phase = event.gesturePhase
            if phase & 1 != 0 {
                scrollWheelTimer?.cancel()
                scrollWheelTimer = nil
                isGestureScrolling = true
                startScrollValue = scrollValue
                startLocation = event.location
                lastLocation = startLocation
                lastTime = event.time
                cummulativeDelta = 0
                return true
            }
            guard phase & 4 != 0 else { return true }
            isGestureScrolling = false
            scrollWheelTimer?.cancel()
            scrollWheelTimer = nil
            let value = scrollValue
            let distance = value - startScrollValue
            // REF-PAGING-005: points per 10 ms of the CGEvent timestamps.
            let speed = (distance * distance).squareRoot() / Double(event.time &- lastTime) * 10_000_000
            guard speed > 2 else {  // REF-PAGING-005
                scrollToPageIndex(currentPageIndex)
                return true
            }
            let count = UInt(pager.pages.count)
            let index: UInt
            if value < 0 {
                index = layoutRTL ? count &- 1 : 0
            } else {
                guard count > 0 else { return true }
                let current = currentPageIndex
                if layoutRTL {
                    let next = value > startScrollValue ? current &- 1 : current &+ 1
                    index = Int(bitPattern: next) < 0 ? 0 : next
                } else {
                    index = min(value <= startScrollValue ? current &- 1 : current &+ 1, count - 1)
                }
            }
            setCurrentPageIndex(index)
        case 16:  // REF-PAGING-006: navigation
            let current = currentPageIndex
            switch event.navigationGestureType {
            case 0, 2:
                setCurrentPageIndex(layoutRTL ? current &+ 1 : current &- 1)
            case 1, 3:
                setCurrentPageIndex(layoutRTL ? current &- 1 : current &+ 1)
            default:
                break
            }
        default:
            break
        }
        return true
    }
}

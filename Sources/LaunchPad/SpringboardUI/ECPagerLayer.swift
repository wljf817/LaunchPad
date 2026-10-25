import QuartzCore

/// The page scroll duration, read at the first scroll of the process and kept; read again while it is
/// negative (REF-PAGING-002).
@MainActor var springboardPageDuration: Float = -1

/// A pager's layer: a horizontally scrolling layer holding the pages' layers side by side
/// (REF-ARCH-007, research paper §6.2).
@MainActor
@objc(ECPagerLayer)
class ECPagerLayer: CALayer, ECEventHandling {
    weak var pager: ECPager?
    @objc let scrollLayer = CAScrollLayer()
    /// The page indicator (REF-PAGING-003). Set once at initialization; copies made by Core Animation
    /// share it.
    @objc nonisolated(unsafe) let controlLayer: ECPagerControlLayer
    // REF-GRID-007: 10 on each side until the controller sets them.
    @objc var leftMargin: CGFloat = 10
    @objc var rightMargin: CGFloat = 10
    @objc var topMargin: CGFloat = 10
    @objc var bottomMargin: CGFloat = 10
    /// The page shown; the pager and the main grid forward to it (REF-PAGING-001).
    var _currentPageIndex: UInt = 0
    /// When the page indicator shows (REF-PAGING-003); 2 for the main grid.
    @objc var pagerControlVisibility = 2
    var layoutRTL = false
    /// The scroll value and the location when the left button was pressed, and the last location and
    /// time seen (REF-PAGING-005).
    var startScrollValue: CGFloat = 0
    var startLocation: CGPoint = .zero
    var lastLocation: CGPoint = .zero
    var lastTime: UInt64 = 0
    var isDragScrolling = false

    @objc(initWithPager:layoutRTL:)
    required init(pager: ECPager?, layoutRTL: Bool) {
        controlLayer = ECPagerControlLayer(pager: pager, layoutRTL: layoutRTL)
        super.init()
        masksToBounds = true
        self.pager = pager
        self.layoutRTL = layoutRTL
        scrollLayer.scrollMode = .horizontally
        sublayers = [scrollLayer, controlLayer]
    }

    nonisolated override init(layer: Any) {
        controlLayer = (layer as! ECPagerLayer).controlLayer
        super.init(layer: layer)
    }

    nonisolated required init?(coder: NSCoder) {
        nil
    }

    // MARK: - Events (research paper §4)

    /// Records the press: the scroll value, the location and the time (REF-PAGING-005).
    @objc(leftMouseDown:)
    func leftMouseDown(_ event: ECEvent) -> Bool {
        startScrollValue = scrollValue
        startLocation = event.location
        lastLocation = startLocation
        lastTime = event.time
        isDragScrolling = false
        return true
    }

    /// Starts drag scrolling once the pointer is REF-PAGING-005's distance from the press
    /// horizontally; from then on the pages follow the pointer with implicit actions disabled. The last
    /// location and time stay those of the press (REF-PAGING-005).
    @objc(leftMouseDragged:)
    func leftMouseDragged(_ event: ECEvent) -> Bool {
        if !isDragScrolling {
            guard abs(startLocation.x - event.location.x) >= 3 else { return true }  // REF-PAGING-005
            isDragScrolling = true
        }
        let disabled = disableActions()
        scrollValue = startScrollValue + (startLocation.x - event.location.x)
        if disabled {
            CATransaction.setDisableActions(false)
        }
        return true
    }

    /// Ends a drag scroll: at or below REF-PAGING-005's speed it scrolls back to the current page;
    /// above it, it goes to the page REF-PAGING-005 picks, with the original's unsigned arithmetic.
    @objc(leftMouseUp:)
    func leftMouseUp(_ event: ECEvent) -> Bool {
        defer { isDragScrolling = false }
        guard isDragScrolling else { return true }
        let value = scrollValue
        let location = event.location
        let dx = location.x - lastLocation.x
        let dy = location.y - lastLocation.y
        // REF-PAGING-005: points per 10 ms of the CGEvent timestamps.
        let speed = (dx * dx + dy * dy).squareRoot() / Double(event.time &- lastTime) * 10_000_000
        guard speed > 2 else {  // REF-PAGING-005
            scrollToPageIndex(currentPageIndex)
            return true
        }
        let count = UInt(pager?.pages.count ?? 0)
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
        return true
    }

    // MARK: - Current page and scrolling

    @objc var currentPageIndex: UInt {
        _currentPageIndex
    }

    /// A page within the page count other than the current one: tells the pager before and after it
    /// scrolls there; the current page only scrolls back into place. Past the end only 0 is kept, for a
    /// pager without pages. Nothing changes while the pager disables scrolling (REF-PAGING-001).
    @objc(setCurrentPageIndex:)
    func setCurrentPageIndex(_ index: UInt) {
        guard !(pager?.disableScrolling ?? false) else { return }
        guard index < UInt(pager?.pages.count ?? 0) else {
            if index == 0 {
                _currentPageIndex = 0
            }
            return
        }
        guard index != _currentPageIndex else {
            scrollToPageIndex(index)
            return
        }
        pager?.willChangeToPageIndex(index)
        _currentPageIndex = index
        scrollToPageIndex(index)
        pager?.didChangeToPageIndex(index)
    }

    /// Scrolls to the page, mirrored right to left, and lays out the page indicator in the same
    /// transaction, so the pages slide and the dots recolor with one duration and curve
    /// (REF-PAGING-002). The original's completion block only records performance marks.
    @objc(scrollToPageIndex:)
    func scrollToPageIndex(_ index: UInt) {
        let count = UInt(pager?.pages.count ?? 0)
        guard index < count else { return }
        CATransaction.begin()
        // REF-OVERLAY-008: slow motion only when allowed and Shift is down.
        CATransaction.setAnimationDuration(Self.scrollDuration(slow: dockGlobals.slowMotionAllowed && ECModalEventController.shiftKeyDown()))
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0, 0, 0.35841, 1.0019))  // REF-PAGING-002
        let page = layoutRTL ? count &+ ~index : index
        scrollLayer.scroll(to: CGPoint(x: scrollLayer.bounds.width * CGFloat(page), y: 0))
        controlLayer.layout()
        CATransaction.commit()
    }

    /// The page scroll duration: 5 s in slow motion; otherwise the preference, 0.5 s when unset, read
    /// while the kept value is negative. A preference that is not a number counts as unset; it is used
    /// in single precision, without clamping (REF-PAGING-002).
    static func scrollDuration(slow: Bool) -> CFTimeInterval {
        if slow {
            return 5  // REF-PAGING-002
        }
        if springboardPageDuration < 0 {
            springboardPageDuration = (UserDefaults.standard.object(forKey: "springboard-page-duration") as? NSNumber)?.floatValue ?? 0.5  // REF-PAGING-002
        }
        return CFTimeInterval(springboardPageDuration)
    }

    /// The scroll layer's offset. Setting it scrolls there in the caller's transaction; past the first
    /// or the last page only a quarter of the way (REF-PAGING-002).
    @objc var scrollValue: CGFloat {
        get { scrollLayer.bounds.minX }
        set {
            guard !(pager?.disableScrolling ?? false) else { return }
            let count = UInt(pager?.pages.count ?? 0)
            let last = bounds.width * CGFloat(count &- 1)
            var value = newValue
            // REF-PAGING-002
            if value < 0 {
                value *= 0.25
            } else if last < value {
                value = last + (value - last) * 0.25
            }
            scrollLayer.scroll(to: CGPoint(x: value, y: 0))
        }
    }

    /// Back to the first page without scrolling, then lays out again (REF-PAGING-001).
    @objc func invalidate() {
        scrollValue = 0
        setCurrentPageIndex(0)
        layout()
    }

    /// Makes a page for every index the pager source has and the pager has not, adding its layer to
    /// the scroll layer, and drops pages from the end when there are too many.
    @objc func layout() {
        guard let pager, let source = pager.pagerSource else { return }
        let pages = pager.pages
        var count = UInt(pages.count)
        let wanted = source.numberOfPages(for: pager)
        if count < wanted {
            while count < wanted {
                if let page = source.makePage(for: pager, at: count), let layer = page.layer {
                    pages.add(page)
                    scrollLayer.addSublayer(layer)
                }
                count += 1
            }
        } else {
            while count > wanted {
                count -= 1
                if let page = pages[Int(count)] as? ECPage {
                    page.layer?.removeFromSuperlayer()
                    pages.removeObject(at: Int(count))
                }
            }
        }
        for case let page as ECPage in pages {
            source.layoutPage!(page, for: pager)
        }
    }
}

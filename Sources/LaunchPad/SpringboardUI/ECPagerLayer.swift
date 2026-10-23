import QuartzCore

/// A pager's layer: a horizontally scrolling layer holding the pages' layers side by side
/// (REF-ARCH-007, research paper §6.2).
@MainActor
@objc(ECPagerLayer)
class ECPagerLayer: CALayer, ECEventHandling {
    weak var pager: ECPager?
    @objc let scrollLayer = CAScrollLayer()
    // REF-GRID-007: 10 on each side until the controller sets them.
    @objc var leftMargin: CGFloat = 10
    @objc var rightMargin: CGFloat = 10
    @objc var topMargin: CGFloat = 10
    @objc var bottomMargin: CGFloat = 10
    /// The page shown; 0 until paging (phase 2).
    @objc private(set) var currentPageIndex: UInt = 0
    /// 2 for the main grid (REF-GRID-007).
    @objc private(set) var pagerControlVisibility = 2
    var layoutRTL = false
    /// Where the left button was pressed, and the last location and time seen (research paper §4).
    var startLocation: CGPoint = .zero
    var lastLocation: CGPoint = .zero
    var lastTime: UInt64 = 0
    var isDragScrolling = false

    @objc(initWithPager:layoutRTL:)
    required init(pager: ECPager?, layoutRTL: Bool) {
        super.init()
        masksToBounds = true
        self.pager = pager
        self.layoutRTL = layoutRTL
        scrollLayer.scrollMode = .horizontally
        sublayers = [scrollLayer]
    }

    nonisolated override init(layer: Any) {
        super.init(layer: layer)
    }

    nonisolated required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    // MARK: - Events (research paper §4)

    /// Records where the press started. The start scroll value comes with the drag scrolling
    /// (phase 2).
    @objc(leftMouseDown:)
    func leftMouseDown(_ event: ECEvent) -> Bool {
        startLocation = event.location
        lastLocation = startLocation
        lastTime = event.time
        isDragScrolling = false
        return true
    }

    /// Drag scrolling is phase 2.
    @objc(leftMouseDragged:)
    func leftMouseDragged(_ event: ECEvent) -> Bool {
        true
    }

    /// Ends a drag scroll (choosing the page is phase 2).
    @objc(leftMouseUp:)
    func leftMouseUp(_ event: ECEvent) -> Bool {
        isDragScrolling = false
        return true
    }

    @objc func invalidate() {
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

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
}

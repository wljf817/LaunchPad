import QuartzCore

/// A pager's layer: a horizontally scrolling layer holding the pages' layers side by side
/// (REF-ARCH-007, research paper §6.2).
@MainActor
@objc(ECPagerLayer)
class ECPagerLayer: CALayer {
    weak var pager: ECPager?
    @objc let scrollLayer = CAScrollLayer()
    var layoutRTL = false

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

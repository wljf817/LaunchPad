import QuartzCore

/// A pager's page indicator (REF-ARCH-007, REF-PAGING-003): one dot per page in a row centered in
/// it, the current page's dot in the on state. Its pager layer places and hides it. Clicking a dot
/// comes with 2.1.2.
@MainActor
@objc(ECPagerControlLayer)
final class ECPagerControlLayer: CALayer {
    weak var _pager: ECPager?
    var _indicatorLayers = NSMutableArray(capacity: 0)
    var _layoutRTL = false

    @objc(initWithPager:layoutRTL:)
    init(pager: ECPager?, layoutRTL: Bool) {
        super.init()
        _pager = pager
        _layoutRTL = layoutRTL
    }

    nonisolated override init(layer: Any) {
        super.init(layer: layer)
    }

    nonisolated required init?(coder: NSCoder) {
        nil
    }

    @objc var indicatorLayers: NSArray {
        _indicatorLayers
    }

    @objc var layoutRTL: Bool {
        get { _layoutRTL }
        set {
            guard _layoutRTL != newValue else { return }
            _layoutRTL = newValue
            layout()
        }
    }

    /// Makes a dot for every page the pager source has and drops the extra ones from the end, then
    /// lines them up: 15 by 15, 5 apart, the row centered and the coordinates truncated, right to left
    /// in reverse (REF-PAGING-003). The page images of the search and game pages come with phase 3.
    @objc func layout() {
        let pager = _pager
        let wanted = pager.flatMap { pager in pager.pagerSource?.numberOfPages(for: pager) } ?? 0
        var count = UInt(_indicatorLayers.count)
        if count < wanted {
            while count < wanted {
                let indicator = ECPagerIndicatorLayer()
                indicator.eventDelegate = self
                _indicatorLayers.add(indicator)
                addSublayer(indicator)
                count += 1
            }
        } else {
            while wanted < count {
                count -= 1
                (_indicatorLayers[Int(count)] as! CALayer).removeFromSuperlayer()
                _indicatorLayers.removeObject(at: Int(count))
            }
        }
        let current = pager?.currentPageIndex ?? 0
        let bounds = bounds
        // REF-PAGING-003
        let width = Double(Int(wanted) - 1) * 5 + Double(wanted) * 15
        let start = _layoutRTL ? width * 0.5 - 15 : -(width * 0.5)
        var x = CGFloat(Int32(bounds.width * 0.5 + start))
        let step: CGFloat = _layoutRTL ? -20 : 20
        let y = CGFloat(Int32(bounds.height * 0.5 - 7.5))
        for case let (index, indicator as ECPagerIndicatorLayer) in _indicatorLayers.enumerated() {
            indicator.index = UInt(index)
            indicator.frame = CGRect(x: x, y: y, width: 15, height: 15)
            indicator.state = current == UInt(index) ? 1 : 0
            indicator.layout()
            x += step
        }
    }
}

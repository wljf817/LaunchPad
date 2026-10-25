import QuartzCore

/// One dot of a page indicator (REF-ARCH-007, REF-PAGING-004): a sublayer drawn as a small circle in
/// the on color for the current page and the off color for the other pages. The images a page can
/// give instead (the search and game pages) come with phase 3.
@MainActor
@objc(ECPagerIndicatorLayer)
final class ECPagerIndicatorLayer: CALayer {
    /// The page this dot stands for.
    @objc var index: UInt = 0
    var _state = 0
    /// Set once at initialization; copies made by Core Animation share them.
    nonisolated(unsafe) let _layer: CALayer
    nonisolated(unsafe) let _onColor: CGColor
    nonisolated(unsafe) let _offColor: CGColor

    override init() {
        // REF-PAGING-004: white, opaque for the current page and at 0.2 for the others.
        _onColor = CGColor(gray: 1, alpha: 1)
        _offColor = CGColor(gray: 1, alpha: 0.2)
        _layer = CALayer()
        super.init()
        _layer.allowsHitTesting = false
        _layer.backgroundColor = _offColor
        addSublayer(_layer)
    }

    nonisolated override init(layer: Any) {
        let indicator = layer as! ECPagerIndicatorLayer
        _layer = indicator._layer
        _onColor = indicator._onColor
        _offColor = indicator._offColor
        super.init(layer: layer)
    }

    nonisolated required init?(coder: NSCoder) {
        nil
    }

    /// 1 for the current page, 0 for the others. Changing it recolors the dot in the caller's
    /// transaction (REF-PAGING-004).
    @objc var state: Int {
        get { _state }
        set {
            guard _state != newValue else { return }
            _state = newValue
            _layer.contents = nil
            _layer.minificationFilter = .linear
            _layer.backgroundColor = newValue == 1 ? _onColor : _offColor
        }
    }

    /// Centers the dot, 8 by 8 with corner radius 4 (REF-PAGING-004).
    @objc func layout() {
        let bounds = bounds
        let x = CGFloat(Int32((bounds.width - 8) * 0.5))
        let y = CGFloat(Int32((bounds.height - 8) * 0.5))
        _layer.cornerRadius = 4
        _layer.frame = CGRect(x: x, y: y, width: 8, height: 8)
    }
}

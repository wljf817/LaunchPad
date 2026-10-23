import QuartzCore

/// The name of an item: a shadowed text layer inside margins (REF-GRID-010, REF-GRID-011).
///
/// Not main-actor isolated, like the text layers it holds (ECTextLayer). It is used on the main
/// thread only.
@objc(ECSBLabelLayer)
class ECSBLabelLayer: CALayer {
    @objc let textLayer = ECShadowTextLayer()
    var scaleFactor: Float = 0
    // REF-GRID-010: 2 points on each side.
    @objc var leftMargin: CGFloat = 2
    @objc var rightMargin: CGFloat = 2
    @objc var topMargin: CGFloat = 2
    @objc var bottomMargin: CGFloat = 2

    @MainActor
    @objc(initWithString:andScaleFactor:)
    init(string: String?, andScaleFactor scaleFactor: Float) {
        super.init()
        let environment = ECSBEnvironment.shared
        textLayer.font = environment.labelFont
        textLayer.fontSize = CGFloat(environment.labelFontSize)
        // REF-GRID-011
        textLayer.foregroundColor = CGColor(gray: 1, alpha: 1)
        textLayer.truncationMode = .middle
        textLayer.textShadowColor = CGColor(gray: 0, alpha: 0.2)
        textLayer.textShadowOffset = CGSize(width: 0, height: -1)
        textLayer.textShadowBlur = 2
        textLayer.alignmentMode = .center
        textLayer.string = string
        self.scaleFactor = scaleFactor
        textLayer.contentsScale = CGFloat(scaleFactor)
        addSublayer(textLayer)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    @objc var string: Any? {
        get { textLayer.string }
        set { textLayer.string = newValue }
    }

    @objc var shadowHidden: Bool {
        get { textLayer.textShadowHidden }
        set { textLayer.textShadowHidden = newValue }
    }

    @objc func setScaleFactor(_ scaleFactor: Float) {
        guard self.scaleFactor != scaleFactor else { return }
        self.scaleFactor = scaleFactor
        textLayer.contentsScale = CGFloat(scaleFactor)
        textLayer.setNeedsDisplay()
    }

    /// The text layer inside the margins.
    @objc func layout() {
        let bounds = bounds
        textLayer.frame = CGRect(x: leftMargin, y: bottomMargin, width: bounds.width - (leftMargin + rightMargin),
                                 height: bounds.height - (bottomMargin + topMargin))
    }

    /// The text's size with the margins, and room for the shadow below: blur less the offset.
    override func preferredFrameSize() -> CGSize {
        let text = textLayer.preferredFrameSize()
        return CGSize(width: text.width + leftMargin + rightMargin,
                      height: text.height + (topMargin + bottomMargin) + (textLayer.textShadowBlur - textLayer.textShadowOffset.height))
    }
}

import QuartzCore

/// A text layer aligned to the layout direction (REF-ARCH-010).
///
/// Not main-actor isolated: Core Animation calls the drawing and sizing methods the text layers
/// override without isolation. It is used on the main thread only.
@objc(ECTextLayer)
class ECTextLayer: CATextLayer {
    override init() {
        super.init()
        alignmentMode = layoutRightToLeft ? .right : .left
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func draw(in ctx: CGContext) {
        ctx.setAllowsFontSubpixelQuantization(true)
        super.draw(in: ctx)
    }
}

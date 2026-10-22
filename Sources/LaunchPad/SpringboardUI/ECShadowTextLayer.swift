import CoreText
import QuartzCore

/// A text layer that draws its text with a shadow (REF-GRID-002).
@objc(ECShadowTextLayer)
class ECShadowTextLayer: ECTextLayer {
    /// A `CGColor`, typed as an object as in the original.
    @objc var textShadowColor: AnyObject?
    @objc var textShadowOffset = CGSize.zero
    @objc var textShadowHidden = false
    /// The height `preferredFrameSize` gives, until the font or its size changes.
    var cachedHeight: CGFloat = 0
    @objc var textShadowBlur: CGFloat = 0

    override init() {
        super.init()
        // REF-GRID-002: the defaults.
        textShadowColor = CGColor(gray: 0, alpha: 1)
        textShadowOffset = CGSize(width: 0, height: 1)
        textShadowHidden = false
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var font: CFTypeRef? {
        get { super.font }
        set {
            super.font = newValue
            cachedHeight = 0
        }
    }

    override var fontSize: CGFloat {
        get { super.fontSize }
        set {
            super.fontSize = newValue
            cachedHeight = 0
        }
    }

    /// The shadow is scaled with the contents, by 0.6 more above 1x (REF-GRID-002).
    override func draw(in ctx: CGContext) {
        if !textShadowHidden, let textShadowColor {
            let color = textShadowColor as! CGColor
            var scale = contentsScale
            if scale > 1 {
                scale *= 0.6  // REF-GRID-002
            }
            ctx.setShadow(offset: CGSize(width: textShadowOffset.width * scale, height: scale * textShadowOffset.height),
                          blur: scale * textShadowBlur, color: color)
        }
        super.draw(in: ctx)
    }

    /// `CATextLayer`'s width, and the font's line height rounded up (REF-GRID-002). The height of
    /// wrapped text comes with the names (1.3.3).
    override func preferredFrameSize() -> CGSize {
        let size = super.preferredFrameSize()
        if cachedHeight == 0 {
            cachedHeight = textHeight(font, size: fontSize)
        }
        return CGSize(width: size.width, height: cachedHeight == 0 ? size.height : cachedHeight)
    }
}

/// The line height of a font (a font, a graphics font or a font name) of `size`: ascent, descent and
/// leading, rounded up; `size` itself when there is no such font. Used for the loading text
/// (REF-GRID-002) and the names' line in the icon size (REF-GRID-006).
func textHeight(_ font: CFTypeRef?, size: CGFloat) -> CGFloat {
    guard let font else { return size }
    let ctFont: CTFont
    switch CFGetTypeID(font) {
    case CGFont.typeID:
        ctFont = CTFontCreateWithGraphicsFont(font as! CGFont, size, nil, nil)
    case CFStringGetTypeID():
        ctFont = CTFontCreateWithName(font as! CFString, size, nil)
    case CTFontGetTypeID():
        ctFont = font as! CTFont
    default:
        return size
    }
    return (CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont)).rounded(.up)
}

// Draws LaunchPad's own search field images, with the names and pixel sizes of the original's
// (REF-SEARCH-003), into Sources/LaunchPad/Resources: ectl_search_background, ectl_search_loupe,
// ectl_search_loupe_rtl and ectl_search_close, each at 1x and 2x. The shapes follow the
// descriptions in REF-SEARCH-003 only; no pixel is taken from the original's files. The 2x image is
// drawn again in twice the pixels, not scaled up from the 1x one. White, sRGB, with alpha.
//
// The stroke widths, the corner radius and the size of the × are this drawing's own choices (the
// reference describes the shapes, not these numbers), chosen by frame comparison; they and the
// difference that remains are recorded in REF-DEV-033.
//
// Usage: swift tools/assets/search-field-images.swift [output directory]

import CoreGraphics
import Foundation
import ImageIO

let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    : URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LaunchPad/Resources", isDirectory: true)

/// Draws in points with the origin at the top left, at `scale` pixels per point, and writes the
/// PNG. `size` is the 1x pixel size (REF-SEARCH-003).
func write(_ name: String, size: CGSize, scale: Int, draw: (CGContext) -> Void) {
    let width = Int(size.width) * scale
    let height = Int(size.height) * scale
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    draw(context)
    let file = scale == 1 ? "\(name).png" : "\(name)@\(scale)x.png"
    let url = output.appendingPathComponent(file)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(url.path)") }
    print("\(file) \(width) × \(height)")
}

/// ectl_search_background, 11 × 22 (REF-SEARCH-003): a rounded rectangle, a 1-point edge at alpha
/// 0x33 and the inside at alpha 0x0F, its outer corners rounded with radius 4; symmetric left to
/// right, so the middle column stretches.
func background(_ context: CGContext) {
    let bounds = CGRect(x: 0, y: 0, width: 11, height: 22)
    let radius: CGFloat = 4
    context.setFillColor(gray: 1, alpha: 0x33 / 255)
    context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()
    context.setBlendMode(.copy)
    context.setFillColor(gray: 1, alpha: 0x0F / 255)
    context.addPath(CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: radius - 1, cornerHeight: radius - 1, transform: nil))
    context.fillPath()
}

/// ectl_search_loupe, 12 × 12 (REF-SEARCH-003): a 1-point ring 9 points across at the top left
/// (filled between the two circles rather than stroked: Core Graphics strokes of width 1 or less
/// are rasterized differently) and a 1.25-point handle from the ring's middle towards the bottom
/// right corner, opaque.
/// Right to left draws it mirrored.
func loupe(rightToLeft: Bool) -> (CGContext) -> Void {
    { context in
        if rightToLeft {
            context.translateBy(x: 12, y: 0)
            context.scaleBy(x: -1, y: 1)
        }
        let ringWidth: CGFloat = 1
        let center = CGPoint(x: 4.5, y: 4.5)
        let inner = 4.5 - ringWidth
        context.setFillColor(gray: 1, alpha: 1)
        context.addEllipse(in: CGRect(x: 0, y: 0, width: 9, height: 9))
        context.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: 2 * inner, height: 2 * inner))
        context.fillPath(using: .evenOdd)
        let handleWidth: CGFloat = 1.25
        let start = 4.5 + (4.5 - ringWidth / 2) / 2.squareRoot()
        let end: CGFloat = 10.75
        context.setStrokeColor(gray: 1, alpha: 1)
        context.setLineWidth(handleWidth)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: start, y: start))
        context.addLine(to: CGPoint(x: end, y: end))
        context.strokePath()
    }
}

/// ectl_search_close, 14 × 14 (REF-SEARCH-003): an opaque disc with a transparent × cut out.
func close(_ context: CGContext) {
    context.setFillColor(gray: 1, alpha: 1)
    context.fillEllipse(in: CGRect(x: 0, y: 0, width: 14, height: 14))
    context.setBlendMode(.clear)
    context.setLineWidth(1.5)
    context.setLineCap(.round)
    let arm: CGFloat = 3
    context.move(to: CGPoint(x: 7 - arm, y: 7 - arm))
    context.addLine(to: CGPoint(x: 7 + arm, y: 7 + arm))
    context.move(to: CGPoint(x: 7 + arm, y: 7 - arm))
    context.addLine(to: CGPoint(x: 7 - arm, y: 7 + arm))
    context.strokePath()
}

for scale in [1, 2] {
    write("ectl_search_background", size: CGSize(width: 11, height: 22), scale: scale, draw: background)
    write("ectl_search_loupe", size: CGSize(width: 12, height: 12), scale: scale, draw: loupe(rightToLeft: false))
    write("ectl_search_loupe_rtl", size: CGSize(width: 12, height: 12), scale: scale, draw: loupe(rightToLeft: true))
    write("ectl_search_close", size: CGSize(width: 14, height: 14), scale: scale, draw: close)
}

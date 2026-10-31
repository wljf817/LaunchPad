import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PNGFile {
    /// Writes an sRGB PNG without alpha and without time stamps or other
    /// varying metadata, so that the same frame always gives the same bytes.
    public static func write(_ image: FrameImage, to url: URL, dotsPerInch: Double? = nil) throws {
        let data = Data(image.pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let cgImage = CGImage(
                  width: image.width, height: image.height,
                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else { throw InvalidInput("cannot create an image for \(url.path)") }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw InvalidInput("\(url.path) already exists")
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw InvalidInput("cannot create \(url.path)")
        }
        var properties: [CFString: Any] = [:]
        if let dotsPerInch {
            properties[kCGImagePropertyDPIWidth] = dotsPerInch
            properties[kCGImagePropertyDPIHeight] = dotsPerInch
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw InvalidInput("cannot write \(url.path)")
        }
    }

    /// Reads a PNG back as BGRA (used by tests).
    public static func read(_ url: URL) throws -> FrameImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { throw InvalidInput("cannot read \(url.path)") }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw InvalidInput("cannot decode \(url.path)") }
        return FrameImage(width: width, height: height, pixels: pixels)
    }
}

public enum DiffImage {
    /// Pixels with d > threshold are red, masked pixels blue, and the rest grey,
    /// scaled so that d == threshold is white (any d > 0 is white when the
    /// threshold is 0).
    public static func make(_ a: FrameImage, _ b: FrameImage, threshold: Int, mask: PixelMask?) -> FrameImage {
        precondition(a.width == b.width && a.height == b.height)
        var out = [UInt8](repeating: 255, count: a.pixels.count)
        let count = a.width * a.height
        for p in 0..<count {
            let i = p * 4
            if let mask, mask.excluded[p] {
                out[i] = 255; out[i + 1] = 0; out[i + 2] = 0
                continue
            }
            let d = max(
                PixelDiff.absDiff(a.pixels[i], b.pixels[i]),
                PixelDiff.absDiff(a.pixels[i + 1], b.pixels[i + 1]),
                PixelDiff.absDiff(a.pixels[i + 2], b.pixels[i + 2])
            )
            if d > threshold {
                out[i] = 0; out[i + 1] = 0; out[i + 2] = 255
            } else {
                let grey = threshold == 0 ? 0 : UInt8(d * 255 / threshold)
                out[i] = grey; out[i + 1] = grey; out[i + 2] = grey
            }
        }
        return FrameImage(width: a.width, height: a.height, pixels: out)
    }
}

/// The comparison scene's wallpaper. Our own synthetic image, never an Apple
/// wallpaper: a horizontal hue ramp over a vertical brightness ramp, 1-pixel
/// white grid lines every 100 pixels, and a row of solid patches. The strong
/// structure makes blur and colour differences of the background visible.
public enum Wallpaper {
    public static func make(width: Int, height: Int) -> FrameImage {
        var image = FrameImage(width: width, height: height, blue: 0, green: 0, red: 0)
        for y in 0..<height {
            let value = 0.35 + 0.6 * (1 - Double(y) / Double(height))
            for x in 0..<width {
                let (r, g, b) = hsv(hue: Double(x) / Double(width), saturation: 0.65, value: value)
                image.setPixel(x: x, y: y, blue: b, green: g, red: r)
            }
        }
        for y in stride(from: 0, to: height, by: 100) {
            for x in 0..<width { image.setPixel(x: x, y: y, blue: 255, green: 255, red: 255) }
        }
        for x in stride(from: 0, to: width, by: 100) {
            for y in 0..<height { image.setPixel(x: x, y: y, blue: 255, green: 255, red: 255) }
        }
        // Red, green, blue, cyan, magenta, yellow, black, white.
        let patches: [(UInt8, UInt8, UInt8)] = [
            (255, 0, 0), (0, 255, 0), (0, 0, 255), (0, 255, 255),
            (255, 0, 255), (255, 255, 0), (0, 0, 0), (255, 255, 255),
        ]
        for (n, colour) in patches.enumerated() {
            let x0 = 250 + n * 300
            let y0 = 250
            guard x0 < width, y0 < height else { break }
            for y in y0..<min(height, y0 + 200) {
                for x in x0..<min(width, x0 + 200) {
                    image.setPixel(x: x, y: y, blue: colour.2, green: colour.1, red: colour.0)
                }
            }
        }
        return image
    }

    static func hsv(hue: Double, saturation: Double, value: Double) -> (UInt8, UInt8, UInt8) {
        let h = hue * 6
        let sector = Int(h.rounded(.down)) % 6
        let f = h - h.rounded(.down)
        let p = value * (1 - saturation)
        let q = value * (1 - saturation * f)
        let t = value * (1 - saturation * (1 - f))
        let (r, g, b): (Double, Double, Double)
        switch sector {
        case 0: (r, g, b) = (value, t, p)
        case 1: (r, g, b) = (q, value, p)
        case 2: (r, g, b) = (p, value, t)
        case 3: (r, g, b) = (p, q, value)
        case 4: (r, g, b) = (t, p, value)
        default: (r, g, b) = (value, p, q)
        }
        func byte(_ c: Double) -> UInt8 { UInt8((c * 255).rounded()) }
        return (byte(r), byte(g), byte(b))
    }
}

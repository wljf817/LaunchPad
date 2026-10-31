import Foundation

/// A decoded frame: packed 8-bit BGRA, top row first, alpha ignored.
public struct FrameImage: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// A frame filled with one colour.
    public init(width: Int, height: Int, blue: UInt8, green: UInt8, red: UInt8) {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = blue
            pixels[i + 1] = green
            pixels[i + 2] = red
        }
        self.init(width: width, height: height, pixels: pixels)
    }

    public mutating func setPixel(x: Int, y: Int, blue: UInt8, green: UInt8, red: UInt8) {
        let i = (y * width + x) * 4
        pixels[i] = blue
        pixels[i + 1] = green
        pixels[i + 2] = red
    }
}

/// A rectangle in points, origin at the top left of the screen.
public struct PointRect: Codable, Equatable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Parses `x,y,w,h`.
    public init?(_ text: String) {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false).map { Double($0) }
        guard parts.count == 4, let x = parts[0], let y = parts[1], let w = parts[2], let h = parts[3],
              w > 0, h > 0
        else { return nil }
        self.init(x: x, y: y, width: w, height: h)
    }

    public var description: String { "\(x),\(y),\(width),\(height)" }
}

/// Pixels excluded from every measurement, built from rectangles in points.
public struct PixelMask: Sendable {
    public let width: Int
    public let height: Int
    /// `true` for excluded pixels.
    public let excluded: [Bool]

    /// Converts each rectangle to pixels by `scale`, rounding outwards, and
    /// clips it to the frame.
    public init(rects: [PointRect], scale: Int, width: Int, height: Int) {
        var excluded = [Bool](repeating: false, count: width * height)
        let s = Double(scale)
        for rect in rects {
            let x0 = max(0, Int((rect.x * s).rounded(.down)))
            let y0 = max(0, Int((rect.y * s).rounded(.down)))
            let x1 = min(width, Int(((rect.x + rect.width) * s).rounded(.up)))
            let y1 = min(height, Int(((rect.y + rect.height) * s).rounded(.up)))
            guard x0 < x1, y0 < y1 else { continue }
            for y in y0..<y1 {
                for x in x0..<x1 {
                    excluded[y * width + x] = true
                }
            }
        }
        self.width = width
        self.height = height
        self.excluded = excluded
    }
}

/// Measurements of one pair of frames over the pixels outside the mask. The
/// per-pixel difference d is the largest absolute difference of the R, G and
/// B channels (0–255).
public struct FrameMetrics: Codable, Equatable, Sendable {
    /// Pixels outside the mask.
    public var pixelCount: Int
    /// Pixels with d > threshold.
    public var overThresholdCount: Int
    public var overThresholdRatio: Double
    public var maxDelta: Int
    public var meanDelta: Double
    /// `histogram[d]` is the number of pixels with that d.
    public var histogram: [Int]
    /// Bounding box of the pixels with d > threshold, in points; nil when there are none.
    public var boundingBox: PointRect?
}

public enum PixelDiff {
    /// Measures `a` against `b`. Both frames must have the same size, and so must the mask.
    public static func measure(_ a: FrameImage, _ b: FrameImage, threshold: Int, mask: PixelMask?, scale: Int) -> FrameMetrics {
        precondition(a.width == b.width && a.height == b.height)
        let width = a.width
        let height = a.height
        var histogram = [Int](repeating: 0, count: 256)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb in
                histogram.withUnsafeMutableBufferPointer { hist in
                    for y in 0..<height {
                        let row = y * width
                        for x in 0..<width {
                            if let mask, mask.excluded[row + x] { continue }
                            let i = (row + x) * 4
                            let d = max(
                                absDiff(pa[i], pb[i]),
                                absDiff(pa[i + 1], pb[i + 1]),
                                absDiff(pa[i + 2], pb[i + 2])
                            )
                            hist[d] += 1
                            if d > threshold {
                                if x < minX { minX = x }
                                if x > maxX { maxX = x }
                                if y < minY { minY = y }
                                if y > maxY { maxY = y }
                            }
                        }
                    }
                }
            }
        }
        var pixelCount = 0
        var over = 0
        var sum = 0
        var maxDelta = 0
        for (d, n) in histogram.enumerated() where n > 0 {
            pixelCount += n
            sum += d * n
            maxDelta = d
            if d > threshold { over += n }
        }
        var box: PointRect?
        if maxX >= 0 {
            let s = Double(scale)
            box = PointRect(
                x: Double(minX) / s, y: Double(minY) / s,
                width: Double(maxX - minX + 1) / s, height: Double(maxY - minY + 1) / s
            )
        }
        return FrameMetrics(
            pixelCount: pixelCount,
            overThresholdCount: over,
            overThresholdRatio: pixelCount == 0 ? 0 : Double(over) / Double(pixelCount),
            maxDelta: maxDelta,
            meanDelta: pixelCount == 0 ? 0 : Double(sum) / Double(pixelCount),
            histogram: histogram,
            boundingBox: box
        )
    }

    /// Whether any pixel outside the mask has d > threshold.
    public static func differs(_ a: FrameImage, _ b: FrameImage, threshold: Int, mask: PixelMask?) -> Bool {
        precondition(a.width == b.width && a.height == b.height)
        let count = a.width * a.height
        return a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb in
                for p in 0..<count {
                    if let mask, mask.excluded[p] { continue }
                    let i = p * 4
                    if absDiff(pa[i], pb[i]) > threshold
                        || absDiff(pa[i + 1], pb[i + 1]) > threshold
                        || absDiff(pa[i + 2], pb[i + 2]) > threshold
                    {
                        return true
                    }
                }
                return false
            }
        }
    }

    @inline(__always)
    static func absDiff(_ a: UInt8, _ b: UInt8) -> Int {
        a > b ? Int(a &- b) : Int(b &- a)
    }
}

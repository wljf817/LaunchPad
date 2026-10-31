import Testing
@testable import FrameCompare

struct PixelDiffTests {
    @Test func identicalFramesHaveNoDifference() {
        let m = PixelDiff.measure(solid(40), solid(40), threshold: 0, mask: nil, scale: 2)
        #expect(m.maxDelta == 0)
        #expect(m.overThresholdCount == 0)
        #expect(m.histogram[0] == 16 * 10)
        #expect(m.pixelCount == 160)
        #expect(m.boundingBox == nil)
    }

    @Test func thresholdBoundary() {
        var b = solid(40)
        b.setPixel(x: 3, y: 4, blue: 40, green: 45, red: 40)
        let atThreshold = PixelDiff.measure(solid(40), b, threshold: 5, mask: nil, scale: 2)
        #expect(atThreshold.overThresholdCount == 0)
        #expect(atThreshold.maxDelta == 5)
        #expect(!PixelDiff.differs(solid(40), b, threshold: 5, mask: nil))
        let above = PixelDiff.measure(solid(40), b, threshold: 4, mask: nil, scale: 2)
        #expect(above.overThresholdCount == 1)
        #expect(above.overThresholdRatio == 1.0 / 160)
        #expect(PixelDiff.differs(solid(40), b, threshold: 4, mask: nil))
    }

    @Test func largestChannelDifferenceCounts() {
        var b = solid(100)
        b.setPixel(x: 0, y: 0, blue: 99, green: 103, red: 90)
        let m = PixelDiff.measure(solid(100), b, threshold: 0, mask: nil, scale: 2)
        #expect(m.maxDelta == 10)
        #expect(m.histogram[10] == 1)
        #expect(abs(m.meanDelta - 10.0 / 160) < 1e-12)
    }

    @Test func maskExcludesPixels() {
        var b = solid(40)
        b.setPixel(x: 2, y: 2, blue: 200, green: 200, red: 200)
        // Point rect (1, 1, 1, 1) at scale 2 covers pixels 2...3 in x and y.
        let mask = PixelMask(rects: [PointRect(x: 1, y: 1, width: 1, height: 1)], scale: 2, width: 16, height: 10)
        let m = PixelDiff.measure(solid(40), b, threshold: 0, mask: mask, scale: 2)
        #expect(m.overThresholdCount == 0)
        #expect(m.pixelCount == 160 - 4)
        #expect(m.histogram.reduce(0, +) == m.pixelCount)
        #expect(!PixelDiff.differs(solid(40), b, threshold: 0, mask: mask))
    }

    @Test func maskRoundsOutwardsAndClips() {
        let mask = PixelMask(rects: [PointRect(x: 0.25, y: 4.6, width: 1, height: 3)], scale: 2, width: 16, height: 10)
        // x: floor(0.5) = 0 to ceil(2.5) = 3; y: floor(9.2) = 9 to min(10, ceil(15.2)).
        #expect(mask.excluded.filter { $0 }.count == 3)
        #expect(mask.excluded[9 * 16 + 0] && mask.excluded[9 * 16 + 2] && !mask.excluded[9 * 16 + 3])
    }

    @Test func boundingBoxIsInPoints() {
        var b = solid(40)
        b.setPixel(x: 2, y: 4, blue: 0, green: 0, red: 0)
        b.setPixel(x: 7, y: 5, blue: 0, green: 0, red: 0)
        let m = PixelDiff.measure(solid(40), b, threshold: 0, mask: nil, scale: 2)
        #expect(m.boundingBox == PointRect(x: 1, y: 2, width: 3, height: 1))
    }

    @Test func pointRectParsing() {
        #expect(PointRect("0,0,1800,24") == PointRect(x: 0, y: 0, width: 1800, height: 24))
        #expect(PointRect("0,0,0,24") == nil)
        #expect(PointRect("0,0,24") == nil)
    }
}

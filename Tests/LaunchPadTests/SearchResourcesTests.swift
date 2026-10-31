import Foundation
import QuartzCore
import Testing
@testable import LaunchPad

/// What the search field is built from: the image cache (REF-SEARCH-003) and the strings
/// (REF-SEARCH-004, REF-SEARCH-007). Each cache test uses a cache of its own and the images of
/// `testResources` (`testImageFiles`).
struct SearchResourcesTests {
    init() {
        launchPadBundle = testResources
    }

    // MARK: - Image cache (REF-SEARCH-003)

    @Test("共享缓存的队列名是 multiscaleimagecache")
    func sharedCache() {
        #expect(ECMultiScaleImageCache.sharedCache._queue.label == "multiscaleimagecache")
    }

    @Test("缩放比 1 取到 1x、2 取到 2x")
    func scaleFactors() throws {
        let cache = ECMultiScaleImageCache()
        let one = try #require(cgImage(cache.image(withName: "lptest_image", andScaleFactor: 1, removingOtherScaleFactors: true)))
        let two = try #require(cgImage(cache.image(withName: "lptest_image", andScaleFactor: 2, removingOtherScaleFactors: true)))
        #expect(one.width == 3)
        #expect(two.width == 6)
    }

    @Test("只有 1x 时缩放比 2 取到 1x")
    func fallsBackToOneX() throws {
        let cache = ECMultiScaleImageCache()
        let image = try #require(cgImage(cache.image(withName: "lptest_image_1x_only", andScaleFactor: 2, removingOtherScaleFactors: true)))
        #expect(image.width == 4)
    }

    @Test("缩放比 0 取不到图")
    func scaleFactorZero() {
        let cache = ECMultiScaleImageCache()
        #expect(cgImage(cache.image(withName: "lptest_image", andScaleFactor: 0, removingOtherScaleFactors: true)) == nil)
        #expect(cgImage(cache.image(withName: "lptest_image_1x_only", andScaleFactor: 0, removingOtherScaleFactors: true)) == nil)
    }

    @Test("同名同缩放比第二次得到同一个对象，不再读文件")
    func loadsOnce() throws {
        let cache = ECMultiScaleImageCache()
        let first = try #require(cgImage(cache.image(withName: "lptest_image_once", andScaleFactor: 1, removingOtherScaleFactors: true)))
        try FileManager.default.removeItem(at: testResources.bundleURL.appendingPathComponent("lptest_image_once.png"))
        let second = try #require(cgImage(cache.image(withName: "lptest_image_once", andScaleFactor: 1, removingOtherScaleFactors: true)))
        #expect(first === second)
    }

    @Test("新建一种缩放比的条目时丢掉另一种；再取同一种是同一个图")
    func removesTheOtherScaleFactor() throws {
        let cache = ECMultiScaleImageCache()
        let one = try #require(cgImage(cache.image(withName: "lptest_image", andScaleFactor: 1, removingOtherScaleFactors: true)))
        let two = try #require(cgImage(cache.image(withName: "lptest_image", andScaleFactor: 2, removingOtherScaleFactors: true)))
        #expect(cgImage(cache.image(withName: "lptest_image", andScaleFactor: 2, removingOtherScaleFactors: true)) === two)

        // The 1x entry was dropped: a new one is read, and it drops the 2x one.
        let oneAgain = try #require(cgImage(cache.image(withName: "lptest_image", andScaleFactor: 1, removingOtherScaleFactors: true)))
        #expect(oneAgain !== one)
        #expect(oneAgain.width == 3)
        let twoAgain = try #require(cgImage(cache.image(withName: "lptest_image", andScaleFactor: 2, removingOtherScaleFactors: false)))
        #expect(twoAgain !== two)
        #expect(twoAgain.width == 6)
    }

    @Test("removingOtherScaleFactors 为 NO 时不丢；已有的条目再取时也不丢")
    func keepsTheOtherScaleFactor() throws {
        let cache = ECMultiScaleImageCache()
        let one = try #require(cgImage(cache.image(withName: "lptest_image", andScaleFactor: 1, removingOtherScaleFactors: false)))
        let two = try #require(cgImage(cache.image(withName: "lptest_image", andScaleFactor: 2, removingOtherScaleFactors: false)))
        #expect(cgImage(cache.image(withName: "lptest_image", andScaleFactor: 1, removingOtherScaleFactors: true)) === one)
        #expect(cgImage(cache.image(withName: "lptest_image", andScaleFactor: 2, removingOtherScaleFactors: true)) === two)
    }

    /// The cache's image as the `CGImage` it is.
    func cgImage(_ image: Any?) -> CGImage? {
        image.map { $0 as! CGImage }
    }
}

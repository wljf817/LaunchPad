import Foundation
import LaunchPadPrivate
import QuartzCore
import Testing
@testable import LaunchPad

/// The centered single row of search pages (REF-GRID-008).
@MainActor
@Suite(.serialized)
struct FilteringTests {
    // MARK: - Centering a single row (REF-GRID-008)

    /// A grid layer of 5 × 7 cells over 1234 × 757, so 176 points a column, laid out with `count`
    /// items; returns the x of every item layer.
    func itemXs(count: UInt, centered: Bool, rtl: Bool = false) -> [CGFloat] {
        let source = FilteringLayerSource(count: count)
        let gridLayer = ECSBGridLayer(layerSource: source, rows: 5, columns: 7, scaleFactor: 1, layoutRTL: rtl)
        gridLayer.centerSingleRow = centered
        gridLayer.frame = CGRect(x: 0, y: 0, width: 1234, height: 757)
        gridLayer.layout()
        return (gridLayer.itemLayers as! [CALayer]).map(\.position.x)
    }

    @Test("单行居中：3 项时整行右移 352，从右到左时镜像")
    func centeredRow() {
        #expect(itemXs(count: 3, centered: true) == [440, 616, 792])
        #expect(itemXs(count: 3, centered: true, rtl: true) == [794, 618, 442])
    }

    @Test("单行居中：项数等于列数时与不居中相同")
    func fullRow() {
        #expect(itemXs(count: 7, centered: true) == [88, 264, 440, 616, 792, 968, 1144])
    }

    @Test("不居中时 3 项从左边排起")
    func notCentered() {
        #expect(itemXs(count: 3, centered: false) == [88, 264, 440])
    }

}

/// Makes a plain layer for every item.
@MainActor
final class FilteringLayerSource: NSObject, ECLayerSource {
    let count: UInt

    init(count: UInt) {
        self.count = count
    }

    func numberOfItems(for layer: CALayer) -> UInt {
        count
    }

    func setContent(inLayers layers: NSArray, withDataRange range: NSRange, for layer: CALayer, usingScaleFactor scaleFactor: Float) {}

    func makeLayer(for layer: CALayer, at index: UInt) -> CALayer? {
        CALayer()
    }
}

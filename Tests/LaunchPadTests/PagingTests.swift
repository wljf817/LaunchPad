import CoreGraphics
import LaunchPadPrivate
import QuartzCore
import Testing
@testable import LaunchPad

/// The page indicator (REF-PAGING-004), checked against the values the original
/// showed in the reference VM.
@MainActor
@Suite(.serialized)
struct PagingTests {
    func components(_ color: CGColor?) -> [CGFloat] {
        color?.components ?? []
    }

    // MARK: - Dots (REF-PAGING-004)

    @Test("圆点：里面的 layer 不参与命中、颜色是「其他」；布局后居中 8×8、圆角 4")
    func indicatorLayout() throws {
        let dot = ECPagerIndicatorLayer()
        #expect(dot.sublayers?.count == 1)
        let inner = try #require(dot.sublayers?.first)
        #expect(inner.allowsHitTesting == false)
        #expect(components(inner.backgroundColor) == [1, 0.2])
        #expect(dot.state == 0)
        dot.frame = CGRect(x: 740, y: 0, width: 15, height: 15)
        dot.layout()
        #expect(inner.frame == CGRect(x: 3, y: 3, width: 8, height: 8))
        #expect(inner.cornerRadius == 4)
    }

    @Test("圆点的状态：1 是「当前」、0 是「其他」；值不变时不重设颜色")
    func indicatorState() throws {
        let dot = ECPagerIndicatorLayer()
        let inner = try #require(dot.sublayers?.first)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.state = 1
        #expect(components(inner.backgroundColor) == [1, 1])
        inner.backgroundColor = CGColor(gray: 0.5, alpha: 1)
        dot.state = 1
        #expect(components(inner.backgroundColor) == [0.5, 1])
        dot.state = 0
        #expect(components(inner.backgroundColor) == [1, 0.2])
        #expect(inner.contents == nil)
        #expect(inner.minificationFilter == .linear)
        CATransaction.commit()
    }

    /// A window whose layer tree runs implicit animations, as `WindowTests` makes one.
    func makeWindow() -> WALayerKitWindow {
        WindowTests.waitForMenuBar()
        let display = CGMainDisplayID()
        let window = WALayerKitWindow(frame: CGDisplayBounds(display), connection: UInt32(bitPattern: CGSMainConnectionID()),
                                      display: display, tags: 0x400, level: 20)
        CATransaction.flush()
        return window
    }

    @Test("圆点在显式事务里改状态时颜色有动画，关掉隐式动画时没有")
    func indicatorStateAnimation() throws {
        let window = makeWindow()
        let animated = ECPagerIndicatorLayer()
        let still = ECPagerIndicatorLayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.layer.addSublayer(animated)
        window.layer.addSublayer(still)
        CATransaction.commit()
        CATransaction.flush()

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.5)
        animated.state = 1
        CATransaction.commit()
        let inner = try #require(animated.sublayers?.first)
        let animation = try #require(inner.animation(forKey: "backgroundColor") as? CABasicAnimation)
        #expect(animation.duration == 0.5)
        #expect(components((animation.fromValue as! CGColor)) == [1, 0.2])

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        still.state = 1
        CATransaction.commit()
        #expect(still.sublayers?.first?.animation(forKey: "backgroundColor") == nil)

        animated.removeFromSuperlayer()
        still.removeFromSuperlayer()
    }
}

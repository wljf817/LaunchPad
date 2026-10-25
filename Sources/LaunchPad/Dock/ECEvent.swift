import CoreGraphics
import QuartzCore

/// Dock's event object (app-architecture: kept): wraps a window-server event and reads every value
/// from it when asked, together with the layer and window the dispatcher hit and the modal handler
/// it went to (REF-OVERLAY-009). Here the event is the `CGEvent` of an AppKit event.
@MainActor
@objc(ECEvent)
final class ECEvent: NSObject {
    private var _event: AnyObject?
    @objc var hitLayer: CALayer?
    @objc var hitWindow: WALayerKitWindow?
    private weak var _session: AnyObject?
    /// The distance from the press, set by the dispatcher on drags.
    @objc var draggedDelta: CGPoint = .zero

    @objc(initWithEvent:hitLayer:hitWindow:session:)
    init(event: AnyObject?, hitLayer: CALayer?, hitWindow: WALayerKitWindow?, session: AnyObject?) {
        _event = event
        self.hitLayer = hitLayer
        self.hitWindow = hitWindow
        _session = session
        super.init()
    }

    /// The `CGEvent`, kept as an object as in the original.
    @objc var event: AnyObject? {
        _event
    }

    /// The modal handler the event went to.
    @objc var session: AnyObject? {
        _session
    }

    private var cgEvent: CGEvent? {
        _event.map { $0 as! CGEvent }
    }

    /// The `CGEventType` value.
    @objc var type: Int64 {
        guard let cgEvent else { return 0 }
        return Int64(cgEvent.type.rawValue)
    }

    /// Global location, origin at the top left.
    @objc var location: CGPoint {
        cgEvent?.location ?? .zero
    }

    @objc var time: UInt64 {
        cgEvent?.timestamp ?? 0
    }

    @objc var flags: UInt64 {
        cgEvent?.flags.rawValue ?? 0
    }

    /// Integer field 78: the character of a key event, for example 0x1b for Escape (REF-OVERLAY-009).
    @objc var keyData: UInt16 {
        field(78)
    }

    /// Integer field 64 of a notification event (REF-OVERLAY-009).
    @objc var notifyCode: UInt16 {
        field(64)
    }

    /// The horizontal scroll delta: integer field 94, 16.16 fixed point (REF-OVERLAY-009).
    @objc var deltaX: Double {
        Double(integerField(94)) / 65536
    }

    /// The vertical scroll delta: integer field 93, 16.16 fixed point (REF-OVERLAY-009).
    @objc var deltaY: Double {
        Double(integerField(93)) / 65536
    }

    /// Whether the scroll event has a momentum phase: integer field 123 (REF-OVERLAY-009).
    @objc var isMomentum: Bool {
        integerField(123) != 0
    }

    /// The gesture's type: integer field 110 (REF-OVERLAY-009).
    @objc var gestureType: Int64 {
        integerField(110)
    }

    /// The gesture's phase: began 1, changed 2, ended 4, cancelled 8, from the low byte of integer
    /// field 132; any other value is 0 (REF-OVERLAY-009).
    @objc var gesturePhase: UInt64 {
        let phases: [UInt64] = [1, 2, 0, 4, 0, 0, 0, 8]  // REF-OVERLAY-009
        let index = Int(UInt8(truncatingIfNeeded: integerField(132) &- 1))
        return index < phases.count ? phases[index] : 0
    }

    /// The direction of a navigation gesture (gesture type 16) from integer fields 115 and 136;
    /// `Int64.max` for any other gesture or direction (REF-OVERLAY-009).
    @objc var navigationGestureType: Int64 {
        guard integerField(110) == 16 else { return .max }
        let bit = integerField(136) & 1
        switch integerField(115) {  // REF-OVERLAY-009
        case 1: return 1
        case 2: return 0
        case 4: return bit | 2
        case 8: return bit ^ 3
        default: return .max
        }
    }

    /// Drops the event and everything it refers to once the dispatcher is done with it.
    @objc func invalidate() {
        hitLayer = nil
        hitWindow = nil
        _event = nil
        _session = nil
    }

    private func field(_ number: UInt32) -> UInt16 {
        guard let cgEvent, let field = CGEventField(rawValue: number) else { return 0 }
        return UInt16(truncatingIfNeeded: cgEvent.getIntegerValueField(field))
    }

    private func integerField(_ number: UInt32) -> Int64 {
        guard let cgEvent, let field = CGEventField(rawValue: number) else { return 0 }
        return cgEvent.getIntegerValueField(field)
    }
}

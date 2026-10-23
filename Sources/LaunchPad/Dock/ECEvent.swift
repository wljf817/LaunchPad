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
}

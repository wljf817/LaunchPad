import Foundation
import LaunchPadPrivate

/// Dock's modal event controller (app-architecture: kept). The handler stack and event dispatch are
/// 1.4; 1.2 uses the Shift state for slow motion (REF-OVERLAY-008).
@MainActor
@objc(ECModalEventController)
final class ECModalEventController: NSObject {
    /// The live state of the Shift key, not the triggering event's flags.
    @objc class func shiftKeyDown() -> Bool {
        CGSInputModifierKeyState(0, 1)
    }
}

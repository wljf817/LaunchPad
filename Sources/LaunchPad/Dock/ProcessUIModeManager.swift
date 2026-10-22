import AppKit
import LaunchPadPrivate

/// Dock's record of the frontmost app's presentation mode (REF-ARCH-010).
@MainActor
@objc(ProcessUIModeManager)
final class ProcessUIModeManager: NSObject {
    /// NO while the frontmost app has disabled process switching: bit 0x8 of its presentation
    /// options in LaunchServices, the data Dock's record comes from (REF-DEV-007).
    @objc var processSwitchEnabled: Bool {
        guard let front = _LSCopyFrontApplication(-2),
              let options = _LSCopyApplicationInformationItem(-2, front, _kLSUIPresentationOptionsKey) as? NSNumber
        else { return true }
        return options.uint64Value & 0x8 == 0
    }
}

@MainActor let processUIModeManager = ProcessUIModeManager()

import AppKit
import LaunchPadPrivate

/// Mission Control, which lives in the Dock (REF-ARCH-010, REF-DEV-005).
@MainActor
@objc(WVExpose)
final class WVExpose: NSObject {
    /// Non-zero while Mission Control is up: the Dock then has a full-screen window at level 18
    /// (REF-DEV-005).
    @objc var mode: Int {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let screens = NSScreen.screens.compactMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map {
                CGDisplayBounds($0.uint32Value)
            }
        }
        // The owner's name is localized; the Dock is found by its process.
        let dock = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .map(\.processIdentifier))
        for info in windows where (info[kCGWindowOwnerPID as String] as? NSNumber).map({ dock.contains($0.int32Value) }) == true
            && (info[kCGWindowLayer as String] as? Int) == 18 {
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { continue }
            if screens.contains(rect) { return 1 }
        }
        return 0
    }

    /// Makes the Dock leave Mission Control. The Dock's notification toggles it, so it is sent only
    /// when Mission Control is up, as the original only calls `-exit` then (REF-DEV-005).
    @objc func exit() {
        CoreDockSendNotification("com.apple.expose.awake" as CFString, nil)
    }
}

@MainActor let wvExpose = WVExpose()

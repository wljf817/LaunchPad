import AppKit
import ApplicationServices
import LaunchPadPrivate

/// Mission Control, which lives in the Dock (REF-ARCH-010, REF-DEV-005, REF-DEV-026).
@MainActor
@objc(WVExpose)
final class WVExpose: NSObject {
    var observer: AXObserver?

    /// As the Dock's Mission Control closes Launchpad when it changes mode, its accessibility
    /// notifications close it here (REF-DEV-026).
    override init() {
        super.init()
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              AXObserverCreate(dock.processIdentifier, { _, _, _, _ in
                  MainActor.assumeIsolated { wvExpose.changedMode() }
              }, &observer) == .success, let observer else { return }
        let application = AXUIElementCreateApplication(dock.processIdentifier)
        for name in ["AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeShowDesktop"] {
            AXObserverAddNotification(observer, application, name as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    /// Mission Control started a mode: Launchpad closes (REF-DEV-026).
    func changedMode() {
        if let springboard = launchpadSpringboard, springboard.visible {
            springboard.setVisible(false, reason: "WV change mode")
        }
    }

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

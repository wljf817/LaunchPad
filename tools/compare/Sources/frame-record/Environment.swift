import AppKit
import CoreGraphics
import Darwin
import FrameCompare
import Foundation

/// Seconds on the monotonic clock ScreenCaptureKit's display times use
/// (`mach_absolute_time`, the same as `CLOCK_UPTIME_RAW`).
func seconds(machTime: UInt64) -> Double {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(machTime) * Double(info.numer) / Double(info.denom) / 1e9
}

func now() -> Double {
    seconds(machTime: mach_absolute_time())
}

struct ScreenInfo {
    var displayID: CGDirectDisplayID
    var mode: DisplayMode
    var colorSpaceName: String
    var name: String
    var isMain: Bool
}

@MainActor
func screens() -> [ScreenInfo] {
    NSScreen.screens.compactMap { screen in
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let id = CGDirectDisplayID(number.uint32Value)
        var refresh = screen.maximumFramesPerSecond
        if let mode = CGDisplayCopyDisplayMode(id), mode.refreshRate > 0 {
            refresh = Int(mode.refreshRate.rounded())
        }
        return ScreenInfo(
            displayID: id,
            mode: DisplayMode(
                pointWidth: Int(screen.frame.width), pointHeight: Int(screen.frame.height),
                scale: Int(screen.backingScaleFactor), refreshRate: refresh
            ),
            colorSpaceName: screen.colorSpace?.localizedName ?? "unknown",
            name: screen.localizedName,
            isMain: id == CGMainDisplayID()
        )
    }
}

@MainActor
func screen(_ id: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
    }
}

func systemInfo() -> RecordingMetadata.System {
    let plist = NSDictionary(contentsOfFile: "/System/Library/CoreServices/SystemVersion.plist")
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var model = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &model, &size, nil, 0)
    return RecordingMetadata.System(
        productVersion: plist?["ProductVersion"] as? String ?? "unknown",
        buildVersion: plist?["ProductBuildVersion"] as? String ?? "unknown",
        hardwareModel: String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    )
}

@MainActor
func sceneInfo() -> RecordingMetadata.Scene {
    let workspace = NSWorkspace.shared
    // The effective system appearance. The AppleInterfaceStyle default is not
    // reliable: with automatic switching it can read Dark while the system is light.
    let appearance = NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
    return RecordingMetadata.Scene(
        appearance: appearance == .darkAqua ? "dark" : "light",
        // As stored in the global domain, not normalized, so both VMs are read the same way.
        languages: UserDefaults.standard.stringArray(forKey: "AppleLanguages"),
        reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
        reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
        increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast
    )
}

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("frame-record: " + message + "\n").utf8))
    exit(status)
}

import AppKit
import LaunchPadPrivate
import os

/// The desktop picture manager's interface, as far as Launchpad uses it (REF-ARCH-011).
@MainActor
@objc(DPDesktopPictureManagerProtocol) protocol DPDesktopPictureManagerProtocol: NSObjectProtocol {
    @objc(layerForSpace:andDisplay:)
    func layer(forSpace space: ManagedSpace?, andDisplay display: UInt32) -> CALayer
}

/// DockCore's desktop picture manager. In the Dock it owns the wallpaper windows; here the wallpaper
/// windows belong to another process, which is found in the window list (REF-DEV-015).
@MainActor
@objc(_TtC8DockCore35WallpaperAgentDesktopPictureManager)
final class WallpaperAgentDesktopPictureManager: NSObject, DPDesktopPictureManagerProtocol {
    /// A new layer with the capture of the wallpaper window as its contents. The original returns an
    /// empty layer and sets the capture later, from a task on the main actor (REF-OVERLAY-003); here
    /// the capture is made before returning, so that the image is there when the open starts
    /// (REF-DEV-016). The layer is in no layer tree yet, so setting its contents adds no animation.
    func layer(forSpace space: ManagedSpace?, andDisplay display: UInt32) -> CALayer {
        let layer = CALayer()
        guard var window = Self.wallpaperWindow(onDisplay: display) else { return layer }
        // REF-OVERLAY-003: the capture options.
        let images = CGSHWCaptureWindowList(CGSMainConnectionID(), &window, 1, 0x11944) as? [CGImage]
        if let image = images?.first {
            layer.contents = image
        } else {
            Logger().error("Failed to capture the wallpaper window \(window)")
        }
        return layer
    }

    /// The on-screen wallpaper window of the current space on a display (REF-DEV-015).
    static func wallpaperWindow(onDisplay display: UInt32) -> CGWindowID? {
        let bounds = CGDisplayBounds(display)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in windows {
            guard let name = info[kCGWindowName as String] as? String, name.hasPrefix("Wallpaper"),
                  let frame = info[kCGWindowBounds as String] as? NSDictionary,
                  CGRect(dictionaryRepresentation: frame) == bounds,
                  let number = info[kCGWindowNumber as String] as? NSNumber else { continue }
            return number.uint32Value
        }
        return nil
    }
}

@MainActor let gDesktopPictureManager: any DPDesktopPictureManagerProtocol = WallpaperAgentDesktopPictureManager()

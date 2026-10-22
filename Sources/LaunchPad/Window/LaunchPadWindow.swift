import AppKit

/// One of the two windows that make up Launchpad's window (REF-DEV-003). Borderless, transparent,
/// without a shadow; its content view hosts a layer tree: the main window hosts
/// `WALayerKitWindow.layer`, the strip its copy. Not part of the original (app-architecture: the
/// project's own bridging classes). Handing its events to the original's event dispatch is 1.4.
@MainActor
@objc(LaunchPadWindow)
final class LaunchPadWindow: NSWindow {
    init(contentRect: NSRect, hosting layer: CALayer, level: Int32) {
        super.init(contentRect: contentRect, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        self.level = NSWindow.Level(rawValue: Int(level))
        // The original's window belongs to no space and shows on the current one when ordered in
        // (REF-ARCH-008).
        collectionBehavior = [.moveToActiveSpace]
        let view = NSView(frame: NSRect(origin: .zero, size: contentRect.size))
        view.layer = layer
        view.wantsLayer = true
        contentView = view
    }

    override var canBecomeKey: Bool { true }

    /// AppKit moves a window at the strip's level out of the menu bar when it is ordered in; the
    /// strip must stay over the menu bar (REF-DEV-003).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

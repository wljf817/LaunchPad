import AppKit
import QuartzCore

/// A 1 x 1 point window in the top right corner of the recorded display whose color changes in every refresh
/// while recording. In both VMs, when nothing else on the screen changes, ScreenCaptureKit hands over the next
/// change about 0.5 s late, with the content of that later moment and later changes merged into it; with
/// something changing in every refresh it hands over every change in the refresh it is shown (REF-ENV-005).
/// The corner lies inside the privacy indicator's mask that every scene uses (REF-ENV-005).
@MainActor
final class Pacer {
    private let window: NSWindow

    init?(display: CGDirectDisplayID) {
        guard let screen = screen(display) else { return nil }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let frame = screen.frame
        window = NSWindow(contentRect: NSRect(x: frame.maxX - 1, y: frame.maxY - 1, width: 1, height: 1),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.wantsLayer = true
        window.contentView = view
        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = CGColor(gray: 0, alpha: 1)
        animation.toValue = CGColor(gray: 1, alpha: 1)
        animation.duration = 1
        animation.autoreverses = true
        animation.repeatCount = .infinity
        view.layer?.add(animation, forKey: "pace")
        window.orderFrontRegardless()
        CATransaction.flush()
    }

    func stop() {
        window.orderOut(nil)
        CATransaction.flush()
    }
}

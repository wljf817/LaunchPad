import AppKit
import XPC

/// The background process's application delegate (app-architecture: the project's own bridging
/// classes). It creates, activates and starts the controller as Dock's startup does, receives the
/// launcher's toggle message on LaunchPad's Mach service, as the Dock receives `Launchpad.app`'s
/// (REF-ARCH-009, REF-DEV-013), and hands the process's events to Launchpad first while it captures
/// them, as Dock's event loop does (REF-OVERLAY-009).
@MainActor
@objc(LaunchPadAppDelegate)
final class LaunchPadAppDelegate: NSObject, NSApplicationDelegate {
    static let serviceName = "io.github.wljf817.LaunchPad.server"
    static let toggleName = "io.github.wljf817.LaunchPad.toggle"

    var springboard: LPSpringboard?
    var listener: xpc_connection_t?
    var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Creating the Dock's visibility controller removes the Dock's override if a previous run
        // left it on (REF-DEV-004).
        _ = dockBar.visibilityController
        // As Dock: the writing direction is read once, before the controller exists; the preferences
        // are this process's (REF-GRID-009, REF-DEV-002).
        layoutRightToLeft = writingDirectionIsRightToLeft(domain: kCFPreferencesCurrentApplication)
        // As Dock: the controller is activated during the startup and started once it has finished,
        // from the main queue (REF-GRID-001).
        let springboard = LPSpringboard()
        self.springboard = springboard
        springboard.activate()
        DispatchQueue.main.async {
            springboard.start()
        }
        let listener = xpc_connection_create_mach_service(Self.serviceName, .main,
                                                          UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
        xpc_connection_set_event_handler(listener) { peer in
            guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
            let connection = UncheckedBox(peer)
            xpc_connection_set_event_handler(peer) { message in
                guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else { return }
                let name = xpc_dictionary_get_string(message, "notification").map { String(cString: $0) }
                MainActor.assumeIsolated { self.handleNotification(named: name) }
                if let reply = xpc_dictionary_create_reply(message) {
                    xpc_connection_send_message(connection.value, reply)
                }
            }
            // A peer connection does not take the listener's queue.
            xpc_connection_set_target_queue(peer, .main)
            xpc_connection_activate(peer)
        }
        xpc_connection_activate(listener)
        self.listener = listener
        // Every event AppKit dispatches, also the key events that have no key window while LaunchPad
        // has the keyboard focus without being active.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .any) { event in
            let event = UncheckedBox(event)
            return MainActor.assumeIsolated { UncheckedBox(Self.springboardEvent(event.value)) }.value
        }
    }

    /// What Dock's event loop does with an event while Launchpad captures events: hands it to
    /// `-[Springboard handleEvent:]`, except system-defined events and the key events marked as the
    /// app switcher's (flag 0x400). Returns nil when Launchpad handled the event, so AppKit drops it
    /// (REF-OVERLAY-009). The Dock bar's part of that filter does not apply: the Dock's events go to
    /// the Dock's window.
    static func springboardEvent(_ event: NSEvent) -> NSEvent? {
        guard dockGlobals.springboardIsCapturingEvents, let springboard = eventCapturingSpringboard,
              let cgEvent = event.cgEvent else { return event }
        let type = cgEvent.type.rawValue
        // REF-OVERLAY-009: system-defined events (14) and app-switcher key events (10, 11, 12 with 0x400).
        if type == 14 || ([10, 11, 12].contains(type) && cgEvent.flags.rawValue & 0x400 != 0) {
            return event
        }
        return springboard.handleEvent(cgEvent) ? nil : event
    }

    /// The toggle: what the Dock does with `com.apple.launchpad.toggle` (REF-ARCH-009).
    func handleNotification(named name: String?) {
        guard name == Self.toggleName, let springboard else { return }
        springboard.setVisible(!springboard.visible, reason: "Docklet toggle message")
    }
}

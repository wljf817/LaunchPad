import AppKit
import XPC

/// The background process's application delegate (app-architecture: the project's own bridging
/// classes). It creates, activates and starts the controller as Dock's startup does, and receives the
/// launcher's toggle message on LaunchPad's Mach service, as the Dock receives `Launchpad.app`'s
/// (REF-ARCH-009, REF-DEV-013).
@MainActor
@objc(LaunchPadAppDelegate)
final class LaunchPadAppDelegate: NSObject, NSApplicationDelegate {
    static let serviceName = "io.github.wljf817.LaunchPad.server"
    static let toggleName = "io.github.wljf817.LaunchPad.toggle"

    var springboard: LPSpringboard?
    var listener: xpc_connection_t?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Creating the Dock's visibility controller turns auto-hide back on if a previous run left
        // it off (REF-DEV-004).
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
    }

    /// The toggle: what the Dock does with `com.apple.launchpad.toggle` (REF-ARCH-009).
    func handleNotification(named name: String?) {
        guard name == Self.toggleName, let springboard else { return }
        springboard.setVisible(!springboard.visible, reason: "Docklet toggle message")
    }
}

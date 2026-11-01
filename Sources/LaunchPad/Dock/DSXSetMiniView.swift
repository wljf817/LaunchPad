import Foundation
import os
import XPC

/// Dock's handler of `_DSXSetMiniView`, the message AppKit sends when an app sets its Dock tile's mini
/// view (REF-SEARCH-011). Here the text input service sends the same values over its connection and
/// the search field calls this with the service's pid (REF-DEV-034); the message carries no process
/// serial number, so the log line has none. The search field of the pid shows the context and is
/// told, on a global queue over that connection, whether the mini view is shown. The alert panel's
/// branch (`ECAlertPanel`) comes with phase 4.
@MainActor
func DSXSetMiniView(window: UInt32, contextID: UInt32, minimizedWindow: UInt32, pid: pid_t) {
    Logger().info("_DSXSetMiniView window=0x\(window, format: .hex) contextid=0x\(contextID, format: .hex) minimizedWindow=0x\(minimizedWindow, format: .hex) pid=\(pid)")
    guard let layer = ECTextInputLayer.layer(forHelperPID: pid) else {
        Logger().error("MiniView unexpectedly set for pid = \(UInt32(bitPattern: pid), format: .hex), contextid = \(contextID)")
        return
    }
    Logger().debug("ECTI: registerContext for pid = \(UInt32(bitPattern: pid), format: .hex), contextid = \(contextID)")
    layer.registerContext(contextID, window: window)
    // The original finds the port the app registered with the Dock by the field's process serial number.
    guard let connection = layer._connection else { return }
    let peer = UncheckedBox(connection)
    let shown = contextID != 0
    DispatchQueue.global().async {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "request", "miniViewShown")
        xpc_dictionary_set_bool(message, "shown", shown)
        xpc_connection_send_message(peer.value, message)
    }
}

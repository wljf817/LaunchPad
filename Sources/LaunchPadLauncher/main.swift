// LaunchPad's launcher, built like the original's /System/Applications/Launchpad.app: a background
// app that links no AppKit, sends one toggle message and exits (REF-ARCH-009, REF-DEV-013). The
// original sends it to the Dock; this one sends it to LaunchPad's background process, a launchd
// agent with its own Mach service, which it registers on first run.

import Foundation
import ServiceManagement
import XPC

let agent = SMAppService.agent(plistName: "io.github.wljf817.LaunchPad.plist")
if agent.status != .enabled {
    try? agent.register()
}

let connection = xpc_connection_create_mach_service("io.github.wljf817.LaunchPad.server", nil, 0)
xpc_connection_set_event_handler(connection) { _ in }
xpc_connection_activate(connection)
let message = xpc_dictionary_create(nil, nil, 0)
xpc_dictionary_set_string(message, "notification", "io.github.wljf817.LaunchPad.toggle")
// Waits until the background process has received it, so that the launcher does not exit first.
_ = xpc_connection_send_message_with_reply_sync(connection, message)

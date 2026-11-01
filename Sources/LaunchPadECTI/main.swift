import AppKit
import LaunchPadECTIPrivate
import os

// The text input service's entry point (REF-SEARCH-011). Its Info.plist asks for the
// _NSApplicationMain run loop, so xpc_main runs NSApplicationMain: ECTIHelperApp, MainMenu.nib and
// the ECTIHelperDelegate in it. Every connection is a search field's.

/// Connections that have not ended; the service exits when the last one does.
nonisolated(unsafe) var connectionCount = 0

/// A new connection: handled on the main queue and counted.
func handleNewConnection(_ peer: xpc_connection_t) {
    Logger().info("ECTI: _handleNewConnection")
    xpc_connection_set_target_queue(peer, DispatchQueue.main)
    connectionCount += 1
    let box = UncheckedBox(peer)
    xpc_connection_set_event_handler(peer) { event in
        let message = UncheckedBox(event)
        MainActor.assumeIsolated { handleEvent(message.value, peer: box.value) }
    }
    xpc_connection_resume(peer)
}

/// A request goes to the application delegate's handler for it; an error ends the connection, and
/// the service exits at the last one.
@MainActor
func handleEvent(_ event: xpc_object_t, peer: xpc_connection_t) {
    let type = xpc_get_type(event)
    if type == XPC_TYPE_DICTIONARY {
        guard let cRequest = xpc_dictionary_get_string(event, "request") else {
            NSLog("Bad request")
            return
        }
        let request = String(cString: cRequest)
        let delegate = NSApp.delegate as! ECTIHelperDelegate
        switch request {
        case "setup": delegate._handleSetupMessage(event, forPeer: peer)
        case "setupMiniView": delegate._handleSetupMiniViewMessage(event, forPeer: peer)
        case "synchronizeWindowLocation": delegate._handleSynchronizeWindowLocation(event, forPeer: peer)
        case "stringValue": delegate._handleGetStringValue(event, forPeer: peer)
        case "setStringValue": delegate._handleSetStringValue(event)
        case "setPlaceholderValue": delegate._handleSetPlaceholderValue(event)
        case "font": delegate._handleSetFont(event)
        case "foregroundColor": delegate._handleSetForegroundColor(event)
        case "selectAllText": delegate._handleSelectAllText(event)
        case "hasFocus": delegate._handleHasFocus(event)
        // The Dock's notification that the mini view is shown or hidden comes from LaunchPad's
        // background process over this connection instead (REF-DEV-034).
        case "miniViewShown": NSApp.dockTile._setMiniViewShown(xpc_dictionary_get_bool(event, "shown"))
        default: NSLog("Unable to handle request %@", request)
        }
    } else if type == XPC_TYPE_ERROR {
        connectionCount -= 1
        if connectionCount == 0 {
            exit(0)
        }
    }
}

struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

// The handler is passed as the function itself: a closure written here would be main-actor
// isolated, and libxpc calls it off the main thread.
xpc_main(handleNewConnection)

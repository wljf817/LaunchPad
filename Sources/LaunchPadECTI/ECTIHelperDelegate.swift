import AppKit
import CoreText
import LaunchPadECTIPrivate
import os

/// The service's application delegate, and the text field's (REF-SEARCH-011). It sets the text
/// field up from the search field's messages, puts it into the application's Dock tile mini view,
/// whose window the search field hosts, and sends the text back whenever it changes.
@MainActor
@objc(ECTIHelperDelegate)
class ECTIHelperDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    /// The width the setup message gave.
    var _maxSize: Double = 0
    var _textField: NSTextField?
    /// The search field's connection, from the last setup message.
    var _peer: xpc_connection_t?
    var _isSearchField = false
    /// Set by Return and Escape; the next string sent says the editing is complete, once.
    var _editingComplete = false
    var _hasFocus = false
    var _hasMarkedText = false

    @objc var textField: NSTextField? {
        get { _textField }
        set { _textField = newValue }
    }

    /// The cell does not wrap, has the lowered background style and reports marked text; the
    /// delegate is the text field's delegate.
    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger().info("ECTI: applicationDidFinishLaunching")
        let cell = _textField!.cell as! NSTextFieldCell
        cell.wraps = false
        cell.backgroundStyle = .lowered  // REF-SEARCH-011
        cell.setWantsNotificationForMarkedText(true)
        _textField!.delegate = self
    }

    /// After every key: tells the search field when the input method's marked text comes or goes.
    @objc func keyEvent() {
        guard let peer = _peer else { return }
        let hasMarkedText = NSTextInputContext.current?.client.hasMarkedText() ?? false
        guard hasMarkedText != _hasMarkedText else { return }
        _hasMarkedText = hasMarkedText
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "message", "hasMarked")
        xpc_dictionary_set_bool(message, "hasMarked", hasMarkedText)
        xpc_connection_send_message(peer, message)
    }

    /// Does nothing, as in the original.
    @objc func resizeTextFieldToText() {
    }

    /// Sends the text and the text field's width to the search field, with "editing complete" once
    /// after Return or Escape.
    @objc func _controlTextDidChange() {
        if let peer = _peer {
            let message = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(message, "message", "stringUpdate")
            _textField!.stringValue.withCString { string in
                xpc_dictionary_set_string(message, "stringValue", string)
            }
            xpc_dictionary_set_double(message, "fieldWidth", _textField!.frame.width)
            if _editingComplete {
                xpc_dictionary_set_bool(message, "editingComplete", true)
                _editingComplete = false
            }
            xpc_connection_send_message(peer, message)
        }
        resizeTextFieldToText()
    }

    func controlTextDidChange(_ obj: Notification) {
        _controlTextDidChange()
    }

    /// Return and Escape complete the editing and are not handled further; without focus the arrow
    /// keys are swallowed, so the insertion point stays (REF-SEARCH-011).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            _editingComplete = true
            _controlTextDidChange()
            return true
        }
        if !_hasFocus {
            return commandSelector == #selector(NSResponder.moveLeft(_:)) || commandSelector == #selector(NSResponder.moveRight(_:))
                || commandSelector == #selector(NSResponder.moveUp(_:)) || commandSelector == #selector(NSResponder.moveDown(_:))
        }
        return false
    }

    // MARK: - Requests

    /// Keeps the connection, sets the text field up from the message (size, font, color, text,
    /// frame), selects the text, applies the focus and replies with the pid and the process serial
    /// number (REF-SEARCH-011).
    @objc(_handleSetupMessage:forPeer:)
    func _handleSetupMessage(_ message: xpc_object_t, forPeer peer: xpc_connection_t) {
        Logger().info("ECTI: _handleSetupMessage")
        let width = Double(xpc_dictionary_get_uint64(message, "width"))
        let height = Double(xpc_dictionary_get_uint64(message, "height"))
        let string = xpc_dictionary_get_string(message, "stringValue")
        let font = fontFromMessage(message)
        let colorValue = xpc_dictionary_get_value(message, "foregroundColor")
        var color = NSColor(deviceWhite: 0, alpha: 1)  // REF-SEARCH-011
        _peer = peer
        _isSearchField = xpc_dictionary_get_uint64(message, "search_field") != 0
        _maxSize = width
        if let string {
            _textField!.stringValue = String(cString: string)
        }
        if let colorValue, let messageColor = colorFromArray(colorValue) {
            color = messageColor
        }
        _textField!.superview!.setFrameSize(NSSize(width: width, height: height))
        _textField!.isBordered = false
        if let font {
            _textField!.font = font
        }
        _textField!.textColor = color
        _textField!.backgroundColor = .clear
        _ = _textField!.stringValue
        _textField!.frame = NSRect(x: 0, y: _isSearchField ? -3 : -2, width: width, height: height)  // REF-SEARCH-011
        _textField!.needsDisplay = true
        _textField!.selectText(self)
        _handleHasFocus(message)
        guard let reply = xpc_dictionary_create_reply(message) else { return }
        xpc_dictionary_set_uint64(reply, "pid", UInt64(getpid()))
        var psn = CPSProcessSerNum(hi: 0, lo: 0)
        if _CPSGetCurrentProcess(&psn) == noErr {
            xpc_dictionary_set_uint64(reply, "psn", UInt64(psn.hi) << 32 | UInt64(psn.lo))
        }
        xpc_connection_send_message(peer, reply)
    }

    /// Replies with the text, the text field's width and, once after Return or Escape, "editing
    /// complete".
    @objc(_handleGetStringValue:forPeer:)
    func _handleGetStringValue(_ message: xpc_object_t, forPeer peer: xpc_connection_t) {
        guard let reply = xpc_dictionary_create_reply(message) else { return }
        _textField!.stringValue.withCString { string in
            xpc_dictionary_set_string(reply, "stringValue", string)
        }
        xpc_dictionary_set_double(reply, "fieldWidth", _textField!.frame.width)
        if _editingComplete {
            xpc_dictionary_set_bool(reply, "editingComplete", true)
            _editingComplete = false
        }
        xpc_connection_send_message(peer, reply)
    }

    /// The message's text, or an empty one.
    @objc(_handleSetStringValue:)
    func _handleSetStringValue(_ message: xpc_object_t) {
        let string = xpc_dictionary_get_string(message, "stringValue")
        _textField!.stringValue = string.map { String(cString: $0) } ?? ""
        resizeTextFieldToText()
    }

    /// Does nothing, as in the original.
    @objc(_handleSetPlaceholderValue:)
    func _handleSetPlaceholderValue(_ message: xpc_object_t) {
    }

    @objc(_handleSetFont:)
    func _handleSetFont(_ message: xpc_object_t) {
        if let font = fontFromMessage(message) {
            _textField!.font = font
        }
    }

    @objc(_handleSetForegroundColor:)
    func _handleSetForegroundColor(_ message: xpc_object_t) {
        guard let value = xpc_dictionary_get_value(message, "foregroundColor"), let color = colorFromArray(value) else { return }
        _textField!.textColor = color
    }

    /// Lets the Text Services Manager use a remote view, makes the text field's superview the Dock
    /// tile's mini view in a window at level 27 (once), moves that window to the message's location,
    /// which is in the Dock's top-left coordinates, sets the text, selects it and replies with the
    /// text field's width (REF-SEARCH-011).
    @objc(_handleSetupMiniViewMessage:forPeer:)
    func _handleSetupMiniViewMessage(_ message: xpc_object_t, forPeer peer: xpc_connection_t) {
        Logger().info("ECTI: _handleSetupMiniViewMessage")
        _TSMSetRemoteViewActivation(true)
        _TSMRegisterRemoteViewClient(true)
        if NSApp.dockTile.miniView == nil {
            let dockTile = NSApp.dockTile
            dockTile.miniView = _textField!.superview
            // AppKit has sent the mini view's window number and context id to the Dock, which cannot
            // hand them to LaunchPad; the same values go over the search field's connection
            // (REF-DEV-034).
            let window = _textField!.window!
            let handOver = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(handOver, "message", "setMiniView")
            xpc_dictionary_set_uint64(handOver, "window", UInt64(window.windowNumber))
            xpc_dictionary_set_uint64(handOver, "contextid", UInt64(window._contextForLayerHosting().contextId))
            xpc_dictionary_set_uint64(handOver, "minimizedWindow", 0)
            xpc_connection_send_message(peer, handOver)
            dockTile._setMiniViewWindowLevel(27)  // REF-SEARCH-011
            _textField!.window!.delegate = self
        }
        let window = _textField!.window!
        let frame = window.frame
        let x = xpc_dictionary_get_double(message, "locx")
        let zeroScreenHeight = NSScreen._zeroScreenHeight()
        let y = xpc_dictionary_get_double(message, "locy")
        window.setFrame(NSRect(x: x, y: zeroScreenHeight - (frame.height + y), width: frame.width, height: frame.height), display: false)
        _handleSetStringValue(message)
        _textField!.selectText(self)
        guard let reply = xpc_dictionary_create_reply(message) else { return }
        xpc_dictionary_set_double(reply, "fieldWidth", _textField!.frame.width)
        xpc_connection_send_message(peer, reply)
    }

    /// Moves the mini view's window to the message's location (REF-SEARCH-011).
    @objc(_handleSynchronizeWindowLocation:forPeer:)
    func _handleSynchronizeWindowLocation(_ message: xpc_object_t, forPeer peer: xpc_connection_t) {
        Logger().info("ECTI: _handleSynchronizeWindowLocation")
        let window = _textField!.window!
        let frame = window.frame
        let x = xpc_dictionary_get_double(message, "locx")
        let zeroScreenHeight = NSScreen._zeroScreenHeight()
        let y = xpc_dictionary_get_double(message, "locy")
        window._setFrame(NSRect(x: x, y: zeroScreenHeight - (frame.height + y), width: frame.width, height: frame.height))
    }

    @objc(_handleSelectAllText:)
    func _handleSelectAllText(_ message: xpc_object_t) {
        _textField!.selectText(self)
    }

    /// Keeps the focus; with focus the search field's text is aligned naturally, other text
    /// centered (REF-SEARCH-011).
    @objc(_handleHasFocus:)
    func _handleHasFocus(_ message: xpc_object_t) {
        _hasFocus = xpc_dictionary_get_bool(message, "hasFocus")
        guard _hasFocus else { return }
        _textField!.alignment = _isSearchField ? .natural : .center  // REF-SEARCH-011
    }
}

/// The font a message carries: a font descriptor's attributes as a property list (REF-SEARCH-011).
@MainActor
private func fontFromMessage(_ message: xpc_object_t) -> NSFont? {
    var length = 0
    guard let bytes = xpc_dictionary_get_data(message, "font", &length),
          let data = CFDataCreate(nil, bytes.assumingMemoryBound(to: UInt8.self), length),
          let attributes = CFPropertyListCreateWithData(nil, data, 0, nil, nil)?.takeRetainedValue() as? NSDictionary
    else { return nil }
    let descriptor = CTFontDescriptorCreateWithAttributes(attributes)
    return CTFontCreateWithFontDescriptor(descriptor, 0, nil) as NSFont
}

/// A color from four components (device RGBA) or two (device white and alpha); nil otherwise
/// (REF-SEARCH-011).
@MainActor
private func colorFromArray(_ value: xpc_object_t) -> NSColor? {
    guard xpc_get_type(value) == XPC_TYPE_ARRAY else { return nil }
    switch xpc_array_get_count(value) {
    case 4:
        return NSColor(deviceRed: xpc_array_get_double(value, 0), green: xpc_array_get_double(value, 1),
                       blue: xpc_array_get_double(value, 2), alpha: xpc_array_get_double(value, 3))
    case 2:
        return NSColor(deviceWhite: xpc_array_get_double(value, 0), alpha: xpc_array_get_double(value, 1))
    default:
        return nil
    }
}

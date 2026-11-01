import AppKit
import CoreText
import Testing
@testable import LaunchPadECTI

/// The objects of the service's nib: a 626 x 28 view holding the text field (cell ECTITextInputCell)
/// with the delegate as its delegate and outlet, in a window as the mini view puts it. Without the
/// window, selecting the text starts no editing session, whose end would put the field editor's
/// alignment back on the text field.
@MainActor
private final class Service {
    let delegate = ECTIHelperDelegate()
    let field = NSTextField(frame: NSRect(x: 0, y: 3, width: 625, height: 22))
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 626, height: 28))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 626, height: 28), styleMask: [.borderless], backing: .buffered, defer: true)

    init(inWindow: Bool = true) {
        let cell = ECTITextInputCell(textCell: "")
        cell.isEditable = true
        cell.isSelectable = true
        field.cell = cell
        field.alignment = .natural
        view.addSubview(field)
        if inWindow {
            window.contentView!.addSubview(view)
        }
        field.delegate = delegate
        delegate.textField = field
    }
}

/// An in-process connection pair: requests sent from `client` reach the service's handlers with the
/// service side of the connection as the peer, as in the service; what the service sends back is
/// collected.
private final class Link: @unchecked Sendable {
    let listener = xpc_connection_create(nil, nil)
    var client: xpc_connection_t!
    var messages: [xpc_object_t] = []
    var waiting: CheckedContinuation<ServiceBox<xpc_object_t>, Never>?
    let lock = NSLock()

    init(service: Service) {
        let box = ServiceBox(service)
        xpc_connection_set_event_handler(listener) { peer in
            guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
            xpc_connection_set_target_queue(peer, DispatchQueue.main)
            xpc_connection_set_event_handler(peer) { request in
                guard xpc_get_type(request) == XPC_TYPE_DICTIONARY else { return }
                let message = ServiceBox(request)
                let peerBox = ServiceBox(peer)
                MainActor.assumeIsolated { box.value.handle(message.value, peer: peerBox.value) }
            }
            xpc_connection_resume(peer)
        }
        xpc_connection_resume(listener)
        client = xpc_connection_create_from_endpoint(xpc_endpoint_create(listener))
        xpc_connection_set_event_handler(client) { [weak self] message in
            guard let self, xpc_get_type(message) == XPC_TYPE_DICTIONARY else { return }
            self.deliver(message)
        }
        xpc_connection_resume(client)
    }

    func deliver(_ message: xpc_object_t) {
        lock.lock()
        if let waiting {
            self.waiting = nil
            lock.unlock()
            waiting.resume(returning: ServiceBox(message))
        } else {
            messages.append(message)
            lock.unlock()
        }
    }

    /// The next message the service sends that is not a reply.
    func nextMessage() async -> xpc_object_t {
        await withCheckedContinuation { (continuation: CheckedContinuation<ServiceBox<xpc_object_t>, Never>) in
            lock.lock()
            if !messages.isEmpty {
                let message = messages.removeFirst()
                lock.unlock()
                continuation.resume(returning: ServiceBox(message))
            } else {
                waiting = continuation
                lock.unlock()
            }
        }.value
    }

    /// Sends a request and waits for its reply.
    func request(_ message: xpc_object_t) async -> xpc_object_t {
        let box = ServiceBox(message)
        return await withCheckedContinuation { (continuation: CheckedContinuation<ServiceBox<xpc_object_t>, Never>) in
            xpc_connection_send_message_with_reply(client, box.value, DispatchQueue.global()) { reply in
                continuation.resume(returning: ServiceBox(reply))
            }
        }.value
    }
}

private struct ServiceBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

extension Service {
    func handle(_ message: xpc_object_t, peer: xpc_connection_t) {
        switch String(cString: xpc_dictionary_get_string(message, "request")!) {
        case "setup": delegate._handleSetupMessage(message, forPeer: peer)
        case "stringValue": delegate._handleGetStringValue(message, forPeer: peer)
        default: break
        }
    }
}

/// A setup request as the search field sends it: 200 x 25, the search field's flag and focus.
private func setupMessage(searchField: Bool = true, hasFocus: Bool = false, string: String? = nil, color: [Double]? = nil,
                          font: CTFont? = nil) -> xpc_object_t {
    let message = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_string(message, "request", "setup")
    xpc_dictionary_set_uint64(message, "width", 200)
    xpc_dictionary_set_uint64(message, "height", 25)
    xpc_dictionary_set_bool(message, "hasFocus", hasFocus)
    if searchField {
        xpc_dictionary_set_uint64(message, "search_field", 1)
    }
    if let string {
        xpc_dictionary_set_string(message, "stringValue", string)
    }
    if let color {
        let array = xpc_array_create(nil, 0)
        for component in color {
            xpc_array_set_double(array, XPC_ARRAY_APPEND, component)
        }
        xpc_dictionary_set_value(message, "foregroundColor", array)
    }
    if let font {
        putFont(font, in: message)
    }
    return message
}

/// The font as the search field sends it: its descriptor's attributes as a binary property list.
private func putFont(_ font: CTFont, in message: xpc_object_t) {
    let attributes = CTFontDescriptorCopyAttributes(CTFontCopyFontDescriptor(font))
    let data = CFPropertyListCreateData(nil, attributes, .binaryFormat_v1_0, 0, nil)!.takeRetainedValue() as Data
    data.withUnsafeBytes { xpc_dictionary_set_data(message, "font", $0.baseAddress!, data.count) }
}

private func string(_ message: xpc_object_t, _ key: String) -> String? {
    xpc_dictionary_get_string(message, key).map { String(cString: $0) }
}

@MainActor
@Suite struct ECTIHelperDelegateTests {
    @Test func setupStylesTheTextField() async {
        let service = Service()
        let link = Link(service: service)
        _ = await link.request(setupMessage(string: "pro", color: [1, 1], font: CTFontCreateWithName("Helvetica" as CFString, 13, nil)))
        #expect(service.field.isBordered == false)
        #expect(service.field.backgroundColor == NSColor.clear)
        #expect(service.field.font?.fontName == "Helvetica")
        #expect(service.field.font?.pointSize == 13)
        #expect(service.field.textColor == NSColor(deviceWhite: 1, alpha: 1))
        #expect(service.field.frame == NSRect(x: 0, y: -3, width: 200, height: 25))
        #expect(service.field.superview?.frame.size == NSSize(width: 200, height: 25))
        #expect(service.field.stringValue == "pro")
        #expect(service.field.currentEditor()?.selectedRange == NSRange(location: 0, length: 3))
    }

    @Test func setupWithoutColorIsBlack() async {
        let service = Service()
        let link = Link(service: service)
        _ = await link.request(setupMessage())
        #expect(service.field.textColor == NSColor(deviceWhite: 0, alpha: 1))
    }

    @Test func setupWithFourComponents() async {
        let service = Service()
        let link = Link(service: service)
        _ = await link.request(setupMessage(color: [0.25, 0.5, 0.75, 1]))
        #expect(service.field.textColor == NSColor(deviceRed: 0.25, green: 0.5, blue: 0.75, alpha: 1))
    }

    @Test func setupOfAnotherFieldIsTwoPointsLower() async {
        let service = Service()
        let link = Link(service: service)
        _ = await link.request(setupMessage(searchField: false))
        #expect(service.field.frame == NSRect(x: 0, y: -2, width: 200, height: 25))
    }

    @Test func setupRepliesWithThePid() async {
        let service = Service()
        let link = Link(service: service)
        let reply = await link.request(setupMessage())
        #expect(xpc_dictionary_get_uint64(reply, "pid") == UInt64(getpid()))
    }

    @Test func focusCentersAnotherField() async {
        let service = Service(inWindow: false)
        let link = Link(service: service)
        _ = await link.request(setupMessage(searchField: false, hasFocus: true))
        #expect(service.field.alignment == .center)
    }

    @Test func focusAlignsTheSearchFieldNaturally() async {
        let service = Service(inWindow: false)
        let link = Link(service: service)
        _ = await link.request(setupMessage(searchField: false, hasFocus: true))
        _ = await link.request(setupMessage(searchField: true, hasFocus: true))
        #expect(service.field.alignment == .natural)
    }

    @Test func noFocusLeavesTheAlignment() async {
        let service = Service(inWindow: false)
        let link = Link(service: service)
        _ = await link.request(setupMessage(searchField: false, hasFocus: true))
        _ = await link.request(setupMessage(searchField: true, hasFocus: false))
        #expect(service.field.alignment == .center)
    }

    @Test func arrowsAreSwallowedWithoutFocus() async {
        let service = Service()
        let link = Link(service: service)
        _ = await link.request(setupMessage(hasFocus: false))
        let textView = NSTextView()
        for selector in [#selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveUp(_:)),
                         #selector(NSResponder.moveDown(_:))] {
            #expect(service.delegate.control(service.field, textView: textView, doCommandBy: selector) == true)
        }
        #expect(service.delegate.control(service.field, textView: textView, doCommandBy: #selector(NSResponder.deleteBackward(_:))) == false)
    }

    @Test func arrowsGoToTheEditorWithFocus() async {
        let service = Service()
        let link = Link(service: service)
        _ = await link.request(setupMessage(hasFocus: true))
        let textView = NSTextView()
        for selector in [#selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveUp(_:)),
                         #selector(NSResponder.moveDown(_:))] {
            #expect(service.delegate.control(service.field, textView: textView, doCommandBy: selector) == false)
        }
    }

    @Test(arguments: [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:))])
    func returnAndEscapeCompleteTheEditing(selector: Selector) async {
        let service = Service()
        let link = Link(service: service)
        _ = await link.request(setupMessage(string: "pro"))
        #expect(service.delegate.control(service.field, textView: NSTextView(), doCommandBy: selector) == true)
        let update = await link.nextMessage()
        #expect(string(update, "message") == "stringUpdate")
        #expect(string(update, "stringValue") == "pro")
        #expect(xpc_dictionary_get_double(update, "fieldWidth") == 200)
        #expect(xpc_dictionary_get_bool(update, "editingComplete") == true)
        service.delegate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        let next = await link.nextMessage()
        #expect(xpc_dictionary_get_value(next, "editingComplete") == nil)
    }

    @Test func stringValueReplyCarriesEditingCompleteOnce() async {
        let service = Service()
        let link = Link(service: service)
        _ = await link.request(setupMessage(string: "pro"))
        service.delegate._editingComplete = true
        let request = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(request, "request", "stringValue")
        let first = await link.request(request)
        let second = await link.request(request)
        #expect(string(first, "stringValue") == "pro")
        #expect(xpc_dictionary_get_double(first, "fieldWidth") == 200)
        #expect(xpc_dictionary_get_bool(first, "editingComplete") == true)
        #expect(xpc_dictionary_get_value(second, "editingComplete") == nil)
    }

    @Test func setStringValue() {
        let service = Service()
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "stringValue", "pr")
        service.delegate._handleSetStringValue(message)
        #expect(service.field.stringValue == "pr")
        service.delegate._handleSetStringValue(xpc_dictionary_create(nil, nil, 0))
        #expect(service.field.stringValue == "")
    }

    @Test func setFont() {
        let service = Service()
        let message = xpc_dictionary_create(nil, nil, 0)
        putFont(CTFontCreateWithName("Helvetica" as CFString, 13, nil), in: message)
        service.delegate._handleSetFont(message)
        #expect(service.field.font?.fontName == "Helvetica")
        #expect(service.field.font?.pointSize == 13)
    }

    @Test func setForegroundColor() {
        let service = Service()
        let message = xpc_dictionary_create(nil, nil, 0)
        let array = xpc_array_create(nil, 0)
        xpc_array_set_double(array, XPC_ARRAY_APPEND, 0.5)
        xpc_array_set_double(array, XPC_ARRAY_APPEND, 1)
        xpc_dictionary_set_value(message, "foregroundColor", array)
        service.delegate._handleSetForegroundColor(message)
        #expect(service.field.textColor == NSColor(deviceWhite: 0.5, alpha: 1))
    }

    @Test func setForegroundColorIgnoresOtherCounts() {
        let service = Service()
        service.field.textColor = NSColor(deviceWhite: 0.5, alpha: 1)
        let message = xpc_dictionary_create(nil, nil, 0)
        let array = xpc_array_create(nil, 0)
        for component in [0.1, 0.2, 0.3] {
            xpc_array_set_double(array, XPC_ARRAY_APPEND, component)
        }
        xpc_dictionary_set_value(message, "foregroundColor", array)
        service.delegate._handleSetForegroundColor(message)
        #expect(service.field.textColor == NSColor(deviceWhite: 0.5, alpha: 1))
    }

    @Test func placeholderChangesNothing() {
        let service = Service()
        service.field.stringValue = "pro"
        service.field.placeholderString = nil
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "stringValue", "Search")
        service.delegate._handleSetPlaceholderValue(message)
        #expect(service.field.stringValue == "pro")
        #expect(service.field.placeholderString == nil)
    }

    @Test func insertionPointIsWhite() async {
        let service = Service()
        let link = Link(service: service)
        _ = await link.request(setupMessage(string: "pro"))
        let editor = service.field.currentEditor() as? NSTextView
        #expect(editor?.insertionPointColor == NSColor(deviceWhite: 1, alpha: 1))
    }
}

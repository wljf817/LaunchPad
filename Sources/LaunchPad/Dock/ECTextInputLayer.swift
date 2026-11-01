import CoreText
import Foundation
import LaunchPadPrivate
import os
import QuartzCore
import XPC

/// Every text input layer of the process, not retained; created by the first one (REF-SEARCH-001).
@MainActor private var textInputLayers: NSHashTable<ECTextInputLayer>?

/// The text input service the field connects to: the original's `com.apple.dock.ecti`, here the XPC
/// service in the background process's bundle (REF-SEARCH-011).
private let textInputServiceName = "io.github.wljf817.LaunchPad.ecti"

/// Dock's text input layer (REF-SEARCH-001): a search field or a plain text field whose text field
/// lives in the text input service and shows through `_hostLayer` (REF-SEARCH-011). The search type
/// also draws its background, magnifier, placeholder and cancel button.
@MainActor
@objc(ECTextInputLayer)
class ECTextInputLayer: CALayer, ECEventHandling, ECEventHandlingDelegate {
    var _hostLayer: CALayerHost!
    var _magnifyLayer: CALayer?
    var _cancelSearchLayer: CALayer?
    var _placeholderLayer: ECTextLayer?
    var _type = 0
    /// The service's mini view window, from `-registerContext:window:`.
    var _windowID: UInt32 = 0
    var _psn = CPSProcessSerNum(hi: 0, lo: 0)
    /// The pid of the text input service; 0 until it is connected.
    var _pid: pid_t = 0
    var _stringValue: NSString?
    var _placeholderString: NSString?
    var _placeholderAttributes: NSDictionary?
    var _connection_uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    var _size = CGSize.zero
    /// `_hostLayer`'s rectangle on screen as last sent to the service.
    var _globalHostFrame = CGRect.zero
    var _margin: CGFloat = 0
    /// A `CTFont`, typed as an object as in the original.
    var _font: AnyObject?
    var _fontSize: CGFloat = 0
    var _foregroundColor: CGColor?
    var _scaleFactor: Float = 0
    var _mouseDownInHost = false
    var _mouseDownInClear = false
    var _hasConnection = false
    var _connectionInvalid = false
    var _textFieldActive = false
    var _queueEvents = false
    var _fadeWhenNotActive = false
    var _hasFocus = false
    var _updatingValueFromServer = false
    // _isMarked comes with sub-phase 3.4, _visibleBlock (the folder title) with phase 5.
    var _layoutRTL = false
    /// Copies of the events forwarded while `_queueEvents` is set.
    var _queuedEvents: NSMutableArray?
    var _connection: xpc_connection_t?
    var _containerWindow: WALayerKitWindow?
    /// The service's text field width, from its replies and messages.
    var _actualWidth: CGFloat = 0

    /// Registers the layer, makes `_hostLayer` and, for the search type (1), the search layers with a
    /// margin of the height; other types have a margin of 4. The scale factor is set last, so the
    /// search layers are made at scale 0 and get their images then (REF-SEARCH-001).
    @objc(initWithCGSize:type:scaleFactor:layoutRTL:containerWindow:)
    init(cgSize size: CGSize, type: Int, scaleFactor: Float, layoutRTL: Bool, containerWindow: WALayerKitWindow?) {
        super.init()
        if textInputLayers == nil {
            textInputLayers = NSHashTable(options: .weakMemory, capacity: 0)
        }
        textInputLayers!.add(self)
        _type = type
        _size = size
        withUnsafeMutableBytes(of: &_connection_uuid) { uuid_generate($0.baseAddress!.assumingMemoryBound(to: UInt8.self)) }
        _hostLayer = CALayerHost()
        _layoutRTL = layoutRTL
        _containerWindow = containerWindow
        if type == 1 {
            _margin = size.height
            _setupSearchLayers()
        } else {
            _margin = 4  // REF-SEARCH-001
        }
        addSublayer(_hostLayer)
        self.scaleFactor = scaleFactor
        _queueEvents = true
        _hasFocus = false
    }

    nonisolated override init(layer: Any) {
        super.init(layer: layer)
    }

    nonisolated required init?(coder: NSCoder) {
        nil
    }

    /// The registered layer whose service has the pid; nil, with an error logged, when there is none.
    @objc(layerForHelperPID:)
    static func layer(forHelperPID pid: pid_t) -> ECTextInputLayer? {
        if let layers = textInputLayers {
            for case let layer as ECTextInputLayer in layers.objectEnumerator() where layer._pid == pid {
                return layer
            }
        }
        Logger().error("ECTI: layerForHelperPID returning nil for pid \(UInt32(bitPattern: pid), format: .hex)")
        return nil
    }

    /// The background as this layer's contents, its middle column stretched, then the magnifier
    /// (mirrored right to left), the cancel button (hidden, translucent, its events to this layer) and
    /// the placeholder, all at the current scale factor (REF-SEARCH-001).
    @objc func _setupSearchLayers() {
        let cache = ECMultiScaleImageCache.sharedCache
        let background = cache.image(withName: "ectl_search_background", andScaleFactor: _scaleFactor, removingOtherScaleFactors: true)
        contentsScale = CGFloat(_scaleFactor)
        contentsCenter = CGRect(x: 0.5, y: 0, width: 0, height: 1)  // REF-SEARCH-001
        contents = background
        let magnifyLayer = CALayer()
        _magnifyLayer = magnifyLayer
        let cancelSearchLayer = CALayer()
        _cancelSearchLayer = cancelSearchLayer
        let loupe = cache.image(withName: _layoutRTL ? "ectl_search_loupe_rtl" : "ectl_search_loupe", andScaleFactor: _scaleFactor,
                                removingOtherScaleFactors: true)
        magnifyLayer.contentsScale = CGFloat(_scaleFactor)
        magnifyLayer.contents = loupe
        magnifyLayer.contentsGravity = .resizeAspect
        let close = cache.image(withName: "ectl_search_close", andScaleFactor: _scaleFactor, removingOtherScaleFactors: true)
        cancelSearchLayer.contentsScale = CGFloat(_scaleFactor)
        cancelSearchLayer.contents = close
        cancelSearchLayer.contentsGravity = .resizeAspect
        cancelSearchLayer.eventDelegate = self
        cancelSearchLayer.isHidden = true
        cancelSearchLayer.opacity = 0.3  // REF-SEARCH-001
        let placeholderLayer = ECTextLayer()
        _placeholderLayer = placeholderLayer
        addSublayer(placeholderLayer)
        addSublayer(magnifyLayer)
        addSublayer(cancelSearchLayer)
        layout()
    }

    /// `_hostLayer` between the margins; for the search type, the magnifier and the placeholder
    /// centered as a group, or at the leading edge when active, and the cancel button at the other end.
    /// Leaves the current transaction's timing function at ease-in-ease-out (REF-SEARCH-002).
    @objc func layout() {
        let bounds = bounds
        let hostFrame = CGRect(x: _margin, y: 0, width: bounds.width - _margin * 2, height: bounds.height)
        _hostLayer.frame = hostFrame
        guard _type == 1 else { return }
        let preferred = _placeholderLayer?.preferredFrameSize() ?? .zero
        let width = preferred.width
        var height = preferred.height
        if let attributes = _placeholderAttributes {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            if let string = _placeholderLayer?.string as? String {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes as? [NSAttributedString.Key: Any]))
                _ = CTLineGetDefaultBounds(line, &ascent, &descent, &leading)
            }
            height = (ascent + descent + leading).rounded(.up)
        }
        // REF-SEARCH-002
        let magnifierY = (hostFrame.midY - 5).rounded() - 1
        let cancelY = (hostFrame.midY - 6).rounded() - 1
        let placeholderX: CGFloat
        let magnifierX: CGFloat
        let cancelX: CGFloat
        if !_textFieldActive {
            if !_layoutRTL {
                placeholderX = bounds.midX - width * 0.5 + 12
                magnifierX = placeholderX - 20
                cancelX = bounds.width - 14 - 6
            } else {
                placeholderX = bounds.midX - width * 0.5 - 12
                magnifierX = placeholderX + width + 8
                cancelX = 6
            }
        } else if !_layoutRTL {
            magnifierX = 7
            placeholderX = magnifierX + 12 + 8
            cancelX = bounds.width - 14 - 6
        } else {
            magnifierX = bounds.width - 19
            placeholderX = magnifierX - (width + 8)
            cancelX = 6
        }
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        _placeholderLayer?.frame = CGRect(x: placeholderX, y: 4, width: width, height: height)
        _magnifyLayer?.frame = CGRect(x: magnifierX, y: magnifierY, width: 12, height: 12)
        _cancelSearchLayer?.frame = CGRect(x: cancelX, y: cancelY, width: 14, height: 14)
    }

    /// Lays the layers out again (REF-SEARCH-002); then the service's window follows. Core Animation's
    /// setter is not isolated; the layer is used on the main thread only.
    nonisolated override var frame: CGRect {
        get { super.frame }
        set {
            super.frame = newValue
            let layer = UncheckedBox(self)
            MainActor.assumeIsolated {
                layer.value.layout()
                layer.value._synchronizeWindowLocation()
            }
        }
    }

    /// The service's window follows.
    nonisolated override func layoutSublayers() {
        super.layoutSublayers()
        let layer = UncheckedBox(self)
        MainActor.assumeIsolated { layer.value._synchronizeWindowLocation() }
    }

    // MARK: - Properties

    /// For the search type, the images again at the new scale factor and the scale of every layer
    /// (REF-SEARCH-001).
    @objc var scaleFactor: Float {
        get { _scaleFactor }
        set {
            guard _scaleFactor != newValue else { return }
            _scaleFactor = newValue
            guard _type == 1 else { return }
            let cache = ECMultiScaleImageCache.sharedCache
            let background = cache.image(withName: "ectl_search_background", andScaleFactor: _scaleFactor, removingOtherScaleFactors: true)
            contentsScale = CGFloat(_scaleFactor)
            contents = background
            let loupe = cache.image(withName: _layoutRTL ? "ectl_search_loupe_rtl" : "ectl_search_loupe", andScaleFactor: _scaleFactor,
                                    removingOtherScaleFactors: true)
            _magnifyLayer?.contentsScale = CGFloat(_scaleFactor)
            _magnifyLayer?.contents = loupe
            let close = cache.image(withName: "ectl_search_close", andScaleFactor: _scaleFactor, removingOtherScaleFactors: true)
            _cancelSearchLayer?.contentsScale = CGFloat(_scaleFactor)
            _cancelSearchLayer?.contents = close
            _placeholderLayer?.contentsScale = CGFloat(newValue)
        }
    }

    /// The placeholder's font, size and gray, and the attributes `-layout` measures it with
    /// (REF-SEARCH-001).
    @objc func _fontChanged() {
        guard let placeholderLayer = _placeholderLayer, let font = _font else { return }
        let color = CGColor(gray: 1, alpha: 0.36)  // REF-SEARCH-001
        _placeholderAttributes = NSDictionary(objects: [font, color], forKeys: [kCTFontAttributeName as NSString, kCTForegroundColorAttributeName as NSString])
        placeholderLayer.font = font
        placeholderLayer.fontSize = _fontSize
        placeholderLayer.foregroundColor = color
    }

    /// A new font (by identity) restyles the placeholder; the service gets it when connected
    /// (REF-SEARCH-011).
    @objc var font: AnyObject? {
        get { _font }
        set {
            guard _font !== newValue else { return }
            _font = newValue
            _fontChanged()
            guard _hasConnection, let font = _font, let data = fontData(font) else { return }
            let message = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(message, "request", "font")
            data.withUnsafeBytes { xpc_dictionary_set_data(message, "font", $0.baseAddress!, data.count) }
            xpc_connection_send_message(_connection!, message)
        }
    }

    @objc var fontSize: CGFloat {
        get { _fontSize }
        set {
            guard _fontSize != newValue else { return }
            _fontSize = newValue
            _fontChanged()
        }
    }

    /// A new string (by identity) is the placeholder layer's.
    @objc var placeholderString: NSString? {
        get { _placeholderString }
        set {
            guard _placeholderString !== newValue else { return }
            _placeholderString = newValue
            _placeholderLayer?.string = newValue
        }
    }

    /// Kept for the service, which gets a new one when connected (REF-SEARCH-011). The placeholder's
    /// color is its own (`-_fontChanged`).
    @objc var foregroundColor: CGColor? {
        get { _foregroundColor }
        set {
            guard _foregroundColor !== newValue else { return }
            _foregroundColor = newValue
            guard _hasConnection else { return }
            let message = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(message, "request", "foregroundColor")
            if let color = _foregroundColor, let components = colorArray(color) {
                xpc_dictionary_set_value(message, "foregroundColor", components)
            }
            xpc_connection_send_message(_connection!, message)
        }
    }

    /// A new string (by identity) shows the cancel button and hides the placeholder when it is not
    /// empty, the other way round when it is, without implicit actions (REF-SEARCH-005); the service
    /// gets it when connected, unless it came from the service. The grid layer observes it
    /// (REF-SEARCH-008).
    @objc dynamic var stringValue: NSString? {
        get { _stringValue }
        set {
            guard _stringValue !== newValue else { return }
            _stringValue = newValue
            let length = _stringValue?.length ?? 0
            let disabled = disableActions()
            _cancelSearchLayer?.isHidden = length == 0
            _placeholderLayer?.isHidden = length != 0
            if disabled {
                CATransaction.setDisableActions(false)
            }
            if length != 0 || !_hasFocus {
                opacity = 1
            }
            if _hasConnection && !_updatingValueFromServer {
                _sendStringValueMessage()
            }
        }
    }

    /// Deactivating closes the connection; activating clears "connection invalid" and connects
    /// asynchronously on the main queue. Then the layers are laid out for the new state
    /// (REF-SEARCH-002, REF-SEARCH-005, REF-SEARCH-011).
    @objc var textFieldActive: Bool {
        get { _textFieldActive }
        set {
            guard _textFieldActive != newValue else { return }
            _textFieldActive = newValue
            if !newValue {
                _closeConnection()
                if (_stringValue?.length ?? 0) != 0 || !_hasFocus {
                    opacity = 1
                }
            } else {
                _connectionInvalid = false
                DispatchQueue.main.async { self._setupConnection() }
            }
            layout()
        }
    }

    /// Taking focus makes the field active first (REF-SEARCH-005). Then, asynchronously on the main
    /// queue, the service gets the focus when connected, and losing focus without text deactivates the
    /// field (REF-SEARCH-011).
    @objc var hasFocus: Bool {
        get { _hasFocus }
        set {
            guard _hasFocus != newValue else { return }
            _hasFocus = newValue
            if newValue && !_textFieldActive {
                textFieldActive = true
            }
            if _hasFocus {
                opacity = 1
            }
            DispatchQueue.main.async {
                if self._hasConnection {
                    let message = xpc_dictionary_create(nil, nil, 0)
                    xpc_dictionary_set_string(message, "request", "hasFocus")
                    xpc_dictionary_set_bool(message, "hasFocus", self._hasFocus)
                    xpc_connection_send_message(self._connection!, message)
                }
                if !self._hasFocus && (self._stringValue?.length ?? 0) == 0 {
                    self.textFieldActive = false
                }
            }
        }
    }

    /// Never fades the field: a change only sets its opacity to 1 (REF-SEARCH-005).
    @objc var fadeWhenNotActive: Bool {
        get { _fadeWhenNotActive }
        set {
            guard _fadeWhenNotActive != newValue else { return }
            _fadeWhenNotActive = newValue
            opacity = 1
        }
    }

    @objc var containerWindow: WALayerKitWindow? {
        get { _containerWindow }
        set { _containerWindow = newValue }
    }

    @objc var windowID: UInt32 {
        _windowID
    }

    @objc var psn: CPSProcessSerNum {
        _psn
    }

    @objc var actualWidth: CGFloat {
        get { _actualWidth }
        set { _actualWidth = newValue }
    }

    /// The cancel button opaque while pressed (REF-SEARCH-005).
    @objc(_darkenCancelLayer:)
    func _darkenCancelLayer(_ darken: Bool) {
        _cancelSearchLayer?.opacity = darken ? 1 : 0.3  // REF-SEARCH-005
    }

    // MARK: - The text input service (REF-SEARCH-011)

    /// The service's process serial number: the one it sent, else LaunchServices' for its pid.
    @objc func _fetchPSN() -> CPSProcessSerNum {
        if _psn.lo == 0, _pid != 0, let asn = _LSASNCreateWithPid(nil, _pid) {
            if let item = _LSCopyApplicationInformationItem(-2, asn, _kLSASNKey) {
                var psn = _psn
                _LSASNExtractHighAndLowParts(item, &psn.hi, &psn.lo)
                _psn = psn
            } else {
                Logger().error("ECTI: psn for pid \(self._pid) failed")
            }
        }
        return _psn
    }

    /// Connects to the field's own instance of the service on the main queue, then sets it up. The
    /// service's errors and messages: an interrupted connection is set up again, an invalid one is
    /// marked so; `stringUpdate` sets the text; `setMiniView` is the hand-over the Dock gets in the
    /// original (REF-DEV-034).
    @objc func _setupConnection() {
        let connection = xpc_connection_create(textInputServiceName, DispatchQueue.main)
        _connection = connection
        withUnsafeBytes(of: &_connection_uuid) { xpc_connection_set_instance(connection, $0.baseAddress!.assumingMemoryBound(to: UInt8.self)) }
        let layer = UncheckedBox(self)
        let peer = UncheckedBox(connection)
        xpc_connection_set_event_handler(connection) { event in
            let event = UncheckedBox(event)
            MainActor.assumeIsolated {
                let layer = layer.value
                let event = event.value
                let type = xpc_get_type(event)
                if type == XPC_TYPE_ERROR {
                    if event === XPC_ERROR_CONNECTION_INVALID {
                        layer._connectionInvalid = true
                    } else if event === XPC_ERROR_CONNECTION_INTERRUPTED {
                        layer._hasConnection = false
                        layer._pid = 0
                        layer._psn = CPSProcessSerNum(hi: 0, lo: 0)
                        layer._ensureConnection()
                    }
                } else if type == XPC_TYPE_DICTIONARY, let message = xpc_dictionary_get_string(event, "message") {
                    switch String(cString: message) {
                    case "stringUpdate":
                        let string = xpc_dictionary_get_string(event, "stringValue").map { NSString(utf8String: $0)! } ?? ""
                        layer._updateStringValue(string, width: xpc_dictionary_get_double(event, "fieldWidth"),
                                                 complete: xpc_dictionary_get_bool(event, "editingComplete"))
                    case "hasMarked":
                        // Kept in _isMarked (sub-phase 3.4).
                        break
                    case "setMiniView":
                        // REF-DEV-034: the values AppKit sends the Dock, from the service's process.
                        DSXSetMiniView(window: UInt32(truncatingIfNeeded: xpc_dictionary_get_uint64(event, "window")),
                                       contextID: UInt32(truncatingIfNeeded: xpc_dictionary_get_uint64(event, "contextid")),
                                       minimizedWindow: UInt32(truncatingIfNeeded: xpc_dictionary_get_uint64(event, "minimizedWindow")),
                                       pid: xpc_connection_get_pid(peer.value))
                    default:
                        break
                    }
                }
            }
        }
        xpc_connection_resume(connection)
        _ensureConnection()
    }

    /// Sets the service up unless it is connected or the connection is invalid.
    @objc func _ensureConnection() {
        if !_hasConnection && !_connectionInvalid {
            _doCommunicationSetup()
        }
    }

    /// `setup`: the size between the margins, the focus, the font, whether it is a search field, the
    /// text when there is one and the color. The reply's pid and process serial number mark the field
    /// connected, then the mini view is set up.
    @objc func _doCommunicationSetup() {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "request", "setup")
        xpc_dictionary_set_uint64(message, "height", UInt64(_size.height))
        xpc_dictionary_set_uint64(message, "width", UInt64(_size.width + _margin * -2))
        xpc_dictionary_set_bool(message, "hasFocus", _hasFocus)
        if let font = _font, let data = fontData(font) {
            data.withUnsafeBytes { xpc_dictionary_set_data(message, "font", $0.baseAddress!, data.count) }
        }
        if _type == 1 {
            xpc_dictionary_set_uint64(message, "search_field", 1)
        }
        if let string = _stringValue, string.length != 0 {
            xpc_dictionary_set_string(message, "stringValue", string.utf8String!)
        }
        if let color = _foregroundColor, let components = colorArray(color) {
            xpc_dictionary_set_value(message, "foregroundColor", components)
        }
        let layer = UncheckedBox(self)
        xpc_connection_send_message_with_reply(_connection!, message, DispatchQueue.main) { reply in
            let reply = UncheckedBox(reply)
            MainActor.assumeIsolated {
                let layer = layer.value
                let reply = reply.value
                guard layer._connection != nil else { return }
                guard !layer._hasConnection else {
                    NSLog("could not communicate properly")
                    return
                }
                let type = xpc_get_type(reply)
                if type == XPC_TYPE_DICTIONARY {
                    layer._pid = pid_t(truncatingIfNeeded: xpc_dictionary_get_uint64(reply, "pid"))
                    let psn = UInt32(truncatingIfNeeded: xpc_dictionary_get_uint64(reply, "psn"))
                    if psn == 0 {
                        layer._psn = CPSProcessSerNum(hi: 0, lo: 0)
                        layer._psn = layer._fetchPSN()
                    } else {
                        layer._psn = CPSProcessSerNum(hi: 0, lo: psn)
                    }
                } else if type == XPC_TYPE_ERROR {
                    if reply === XPC_ERROR_CONNECTION_INVALID {
                        Logger().error("ECTI: connection invalid")
                    } else if reply === XPC_ERROR_CONNECTION_INTERRUPTED {
                        Logger().error("ECTI: connection interrupted")
                    }
                    return
                }
                layer._hasConnection = true
                layer._sendSetMiniViewMessage()
            }
        }
    }

    /// `setupMiniView`: the text and `_hostLayer`'s origin on screen, which is kept. The reply's width is
    /// kept; then the text is fetched, and once it is here the queued events go out.
    @objc func _sendSetMiniViewMessage() {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "request", "setupMiniView")
        xpc_dictionary_set_string(message, "stringValue", (_stringValue as String?) ?? "")
        _globalHostFrame = _getHostFrame()
        xpc_dictionary_set_double(message, "locx", _globalHostFrame.origin.x)
        xpc_dictionary_set_double(message, "locy", _globalHostFrame.origin.y)
        let layer = UncheckedBox(self)
        xpc_connection_send_message_with_reply(_connection!, message, DispatchQueue.main) { reply in
            let reply = UncheckedBox(reply)
            MainActor.assumeIsolated {
                let layer = layer.value
                guard layer._connection != nil, xpc_get_type(reply.value) == XPC_TYPE_DICTIONARY else { return }
                layer.actualWidth = xpc_dictionary_get_double(reply.value, "fieldWidth")
                layer._getStringValue { _, _, _ in
                    layer._queueEvents = false
                    layer._processPendingEvents()
                }
            }
        }
    }

    /// Asks the service for its text; `block` gets the text, the text field's width and whether editing
    /// completed, or nil, 0 and NO when the reply is not one. Nothing comes once the connection is
    /// closed.
    @objc(_getStringValueWithBlock:)
    func _getStringValue(withBlock block: @escaping (NSString?, CGFloat, Bool) -> Void) {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "request", "stringValue")
        let layer = UncheckedBox(self)
        let block = UncheckedBox(block)
        xpc_connection_send_message_with_reply(_connection!, message, DispatchQueue.main) { reply in
            let reply = UncheckedBox(reply)
            MainActor.assumeIsolated {
                guard layer.value._connection != nil else { return }
                let reply = reply.value
                if xpc_get_type(reply) == XPC_TYPE_DICTIONARY {
                    let string = xpc_dictionary_get_string(reply, "stringValue").map { NSString(utf8String: $0)! }
                    block.value(string, xpc_dictionary_get_double(reply, "fieldWidth"), xpc_dictionary_get_bool(reply, "editingComplete"))
                } else {
                    NSLog("Couldn't get the string value")
                    block.value(nil, 0, false)
                }
            }
        }
    }

    /// The service's text as the field's, not sent back, and its width.
    @objc(_updateStringValue:width:complete:)
    func _updateStringValue(_ string: NSString?, width: CGFloat, complete: Bool) {
        _updatingValueFromServer = true
        stringValue = string
        _updatingValueFromServer = false
        actualWidth = width
        // With `complete`, ECTextInputLayerEditingCompleteNotification (sub-phase 3.4).
    }

    /// `setStringValue` with the text ("" for none).
    @objc func _sendStringValueMessage() {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "request", "setStringValue")
        xpc_dictionary_set_string(message, "stringValue", (_stringValue as String?) ?? "")
        guard let connection = _connection else { return }
        xpc_connection_send_message(connection, message)
    }

    /// Cancels the connection: a new UUID for the next one, which is a new service process; not
    /// connected, no focus, not active, events queued again. The pid, the window and the context stay.
    @objc func _closeConnection() {
        guard let connection = _connection else { return }
        xpc_connection_cancel(connection)
        withUnsafeMutableBytes(of: &_connection_uuid) { uuid_generate($0.baseAddress!.assumingMemoryBound(to: UInt8.self)) }
        _connection = nil
        _hasConnection = false
        _connectionInvalid = false
        _hasFocus = false
        _textFieldActive = false
        _queueEvents = true
    }

    @objc func invalidate() {
        _closeConnection()
    }

    /// The service's mini view window and context, from `DSXSetMiniView` (REF-DEV-034): `_hostLayer`
    /// shows the context, and with one the service's window follows `_hostLayer`. The folder title's
    /// `visibleBlock` gets YES or NO here (phase 5).
    @objc(registerContext:window:)
    func registerContext(_ contextID: UInt32, window: UInt32) {
        _windowID = window
        _hostLayer.contextId = contextID
        if contextID != 0 {
            _synchronizeWindowLocation()
        }
    }

    /// `_hostLayer`'s rectangle on screen: in the root layer, then global (origin at the top left).
    @objc func _getHostFrame() -> CGRect {
        let frame = convert(_hostLayer.frame, to: nil)
        return _containerWindow?.convertRectToGlobal(frame) ?? .zero
    }

    /// When connected with a context and `_hostLayer`'s rectangle on screen changed: keeps it, moves the
    /// service's window there on the Dock's connection and sends `synchronizeWindowLocation` (the move
    /// fails from this process, REF-DEV-034).
    @objc func _synchronizeWindowLocation() {
        guard _hasConnection, _hostLayer.contextId != 0 else { return }
        let frame = _getHostFrame()
        guard !frame.equalTo(_globalHostFrame) else { return }
        _globalHostFrame = frame
        CGSMoveWindow(Int32(bitPattern: dockGlobals.dockConnection), windowID, &_globalHostFrame.origin)
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "request", "synchronizeWindowLocation")
        xpc_dictionary_set_double(message, "locx", _globalHostFrame.origin.x)
        xpc_dictionary_set_double(message, "locy", _globalHostFrame.origin.y)
        xpc_connection_send_message(_connection!, message)
    }

    /// Posts a copy of `event` (a `CGEvent`) to the service, in its window at the location less
    /// `_hostLayer`'s origin on screen; while events are queued, keeps a copy instead.
    @objc(_forwardEvent:)
    func _forwardEvent(_ event: AnyObject?) {
        let event = event as! CGEvent
        if !_queueEvents {
            let copy = event.copy()!
            let location = event.location
            copy.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(_windowID))  // REF-SEARCH-011
            CGEventSetWindowLocation(copy, CGPoint(x: location.x - _globalHostFrame.origin.x, y: location.y - _globalHostFrame.origin.y))
            copy.postToPid(_pid)
        } else {
            if _queuedEvents == nil {
                _queuedEvents = NSMutableArray(capacity: 0)
            }
            _queuedEvents!.add(event.copy()!)
        }
    }

    /// Posts the queued events in order, each with the current event time.
    @objc func _processPendingEvents() {
        guard let events = _queuedEvents else { return }
        _queuedEvents = nil
        for case let event as CGEvent in events {
            event.timestamp = CGSCurrentEventTimestamp()
            _forwardEvent(event)
        }
    }

    /// A key for the service (REF-KEYBOARD-001).
    @objc(handleKeyEvent:)
    func handleKeyEvent(_ event: ECEvent) -> Bool {
        _forwardEvent(event.event)
        return true
    }

    // MARK: - Events (REF-SEARCH-005)

    /// A press on `_hostLayer` goes to the service, and so do the drags, moves and the release after
    /// it. A press on the cancel button darkens it until the release, which clears the text.
    @objc(leftMouseDown:)
    func leftMouseDown(_ event: ECEvent) -> Bool {
        if event.hitLayer === _hostLayer {
            _mouseDownInHost = true
            _forwardEvent(event.event)
        } else if event.hitLayer === _cancelSearchLayer {
            let disabled = disableActions()
            _darkenCancelLayer(true)
            if disabled {
                CATransaction.setDisableActions(false)
            }
            _mouseDownInClear = true
            ECModalEventController.sharedController().addCompletionBlock { _ in
                guard self._mouseDownInClear else { return }
                let disabled = disableActions()
                self._darkenCancelLayer(false)
                if disabled {
                    CATransaction.setDisableActions(false)
                }
                self.stringValue = ""
                self._sendStringValueMessage()
                self._mouseDownInClear = false
            }
        }
        return true
    }

    @objc(leftMouseDragged:)
    func leftMouseDragged(_ event: ECEvent) -> Bool {
        if _mouseDownInHost {
            _forwardEvent(event.event)
        }
        return _mouseDownInHost
    }

    @objc(leftMouseUp:)
    func leftMouseUp(_ event: ECEvent) -> Bool {
        if _mouseDownInHost {
            _mouseDownInHost = false
            _forwardEvent(event.event)
        }
        return true
    }

    @objc(mouseMoved:)
    func mouseMoved(_ event: ECEvent) -> Bool {
        if _mouseDownInHost {
            _forwardEvent(event.event)
        }
        return _mouseDownInHost
    }
}

/// The font's descriptor attributes as a binary property list, when they are a valid XML property
/// list (REF-SEARCH-011).
@MainActor
private func fontData(_ font: AnyObject) -> Data? {
    let attributes = CTFontDescriptorCopyAttributes(CTFontCopyFontDescriptor(font as! CTFont))
    guard CFPropertyListIsValid(attributes, .xmlFormat_v1_0) else { return nil }
    return CFPropertyListCreateData(nil, attributes, .binaryFormat_v1_0, 0, nil)?.takeRetainedValue() as Data?
}

/// The color's components as an XPC array of doubles (REF-SEARCH-011).
@MainActor
private func colorArray(_ color: CGColor) -> xpc_object_t? {
    let array = xpc_array_create(nil, 0)
    for component in color.components ?? [] {
        xpc_array_append_value(array, xpc_double_create(Double(component)))
    }
    return array
}

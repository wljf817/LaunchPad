import CoreText
import Foundation
import LaunchPadPrivate
import os
import QuartzCore

/// Every text input layer of the process, not retained; created by the first one (REF-SEARCH-001).
@MainActor private var textInputLayers: NSHashTable<ECTextInputLayer>?

/// Dock's text input layer (REF-SEARCH-001): a search field or a plain text field whose text field
/// lives in the text input service and shows through `_hostLayer`. The search type also draws its
/// background, magnifier, placeholder and cancel button. The service steps (connection, messages,
/// window location) come with sub-phase 3.3.
@MainActor
@objc(ECTextInputLayer)
class ECTextInputLayer: CALayer, ECEventHandling, ECEventHandlingDelegate {
    var _hostLayer: CALayerHost!
    var _magnifyLayer: CALayer?
    var _cancelSearchLayer: CALayer?
    var _placeholderLayer: ECTextLayer?
    var _type = 0
    /// The pid of the text input service; 0 until it is connected (sub-phase 3.3).
    var _pid: pid_t = 0
    var _stringValue: NSString?
    var _placeholderString: NSString?
    var _placeholderAttributes: NSDictionary?
    var _connection_uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    var _size = CGSize.zero
    var _margin: CGFloat = 0
    /// A `CTFont`, typed as an object as in the original.
    var _font: AnyObject?
    var _fontSize: CGFloat = 0
    var _foregroundColor: CGColor?
    var _scaleFactor: Float = 0
    var _textFieldActive = false
    var _queueEvents = false
    var _fadeWhenNotActive = false
    var _hasFocus = false
    var _layoutRTL = false
    var _containerWindow: WALayerKitWindow?

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

    /// Lays the layers out again (REF-SEARCH-002); then the service's window follows (sub-phase 3.3).
    /// Core Animation's setter is not isolated; the layer is used on the main thread only.
    nonisolated override var frame: CGRect {
        get { super.frame }
        set {
            super.frame = newValue
            let layer = UncheckedBox(self)
            MainActor.assumeIsolated { layer.value.layout() }
            // Sub-phase 3.3: -_synchronizeWindowLocation.
        }
    }

    /// The service's window follows (sub-phase 3.3).
    nonisolated override func layoutSublayers() {
        super.layoutSublayers()
        // Sub-phase 3.3: -_synchronizeWindowLocation.
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
    /// (sub-phase 3.3).
    @objc var font: AnyObject? {
        get { _font }
        set {
            guard _font !== newValue else { return }
            _font = newValue
            _fontChanged()
            // Sub-phase 3.3: sent to the service when connected.
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

    /// Kept for the service, which gets a new one when connected (sub-phase 3.3). The placeholder's
    /// color is its own (`-_fontChanged`).
    @objc var foregroundColor: CGColor? {
        get { _foregroundColor }
        set {
            guard _foregroundColor !== newValue else { return }
            _foregroundColor = newValue
            // Sub-phase 3.3: sent to the service when connected.
        }
    }

    /// A new string (by identity) shows the cancel button and hides the placeholder when it is not
    /// empty, the other way round when it is, without implicit actions (REF-SEARCH-005). The grid layer
    /// observes it (sub-phase 3.2).
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
            // Sub-phase 3.3: sent to the service when connected and not from it.
        }
    }

    /// Lays the layers out for the new state (REF-SEARCH-002, REF-SEARCH-005).
    @objc var textFieldActive: Bool {
        get { _textFieldActive }
        set {
            guard _textFieldActive != newValue else { return }
            _textFieldActive = newValue
            if !newValue {
                // Sub-phase 3.3: -_closeConnection.
                if (_stringValue?.length ?? 0) != 0 || !_hasFocus {
                    opacity = 1
                }
            } else {
                // Sub-phase 3.3: clears the invalid connection and asks for one on the main queue.
            }
            layout()
        }
    }

    /// Taking focus makes the field active first (REF-SEARCH-005).
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
            // Sub-phase 3.3: the focus goes to the service on the main queue.
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

    /// The cancel button opaque while pressed (REF-SEARCH-005).
    @objc(_darkenCancelLayer:)
    func _darkenCancelLayer(_ darken: Bool) {
        _cancelSearchLayer?.opacity = darken ? 1 : 0.3  // REF-SEARCH-005
    }
}

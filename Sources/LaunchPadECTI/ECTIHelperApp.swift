import AppKit

/// The service's application (REF-SEARCH-011). It never takes the key focus, so the focus stays in
/// the process that shows the text; after every key down and key up it lets the delegate check the
/// input method's marked text.
@objc(ECTIHelperApp)
class ECTIHelperApp: NSApplication {
    @objc(_stealKeyFocusWithOptions:)
    func _stealKeyFocus(withOptions options: UInt32) -> Int32 {
        0
    }

    @objc func _releaseKeyFocus() -> Int32 {
        0
    }

    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        if event.type == .keyDown || event.type == .keyUp {
            (delegate as! ECTIHelperDelegate).keyEvent()
        }
    }
}

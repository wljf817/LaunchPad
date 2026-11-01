import AppKit

/// The text field's cell (REF-SEARCH-011): the field editor's insertion point is white.
@objc(ECTITextInputCell)
class ECTITextInputCell: NSTextFieldCell {
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        _ = super.setUpFieldEditorAttributes(textObj)
        if textObj.isFieldEditor {
            (textObj as! NSTextView).insertionPointColor = NSColor(deviceWhite: 1, alpha: 1)  // REF-SEARCH-011
        }
        return textObj
    }
}

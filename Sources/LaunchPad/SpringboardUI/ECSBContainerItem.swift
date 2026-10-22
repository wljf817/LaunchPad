import Foundation

/// An item that holds items: a page or a folder of the grid (research paper §6.1).
@MainActor
@objc(ECSBContainerItem)
class ECSBContainerItem: ECSBItem {
    var _items: NSMutableArray? = NSMutableArray(capacity: 0)

    @objc override var items: NSMutableArray? {
        get { _items }
        set { _items = newValue }
    }
}

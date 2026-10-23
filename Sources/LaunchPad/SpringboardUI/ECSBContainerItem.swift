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

    /// This item, or the first of its items, depth first, that stands for `clientItem`.
    @objc(itemForClientItem:)
    override func item(forClientItem clientItem: AnyObject?) -> ECSBItem? {
        if let found = super.item(forClientItem: clientItem) {
            return found
        }
        for case let item as ECSBItem in _items ?? [] {
            if let found = item.item(forClientItem: clientItem) {
                return found
            }
        }
        return nil
    }
}

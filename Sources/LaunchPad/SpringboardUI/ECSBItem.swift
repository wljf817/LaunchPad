import Foundation

/// A node of the grid's item tree, which mirrors the model tree (REF-ARCH-005, research paper §6.1).
/// An app is an `ECSBItem`; pages and folders are `ECSBContainerItem`s.
@MainActor
@objc(ECSBItem)
class ECSBItem: NSObject {
    @objc weak var parent: ECSBItem?
    /// The model object: an `LPApp`, `LPGroup` or `LPPage`.
    @objc weak var clientItem: AnyObject?
    @objc weak var itemLayer: ECSBItemLayer?

    /// Only containers have items.
    @objc var items: NSMutableArray? {
        get { nil }
        set {}
    }

    /// Asks the data source for `key` of the model object; nil without one (REF-GRID-014).
    @objc(valueForKey:withHandler:andInfo:)
    func value(forKey key: String, withHandler handler: ECSBDataSource?, andInfo info: NSDictionary?) -> AnyObject? {
        guard let clientItem else { return nil }
        return handler?.value(forKey: key, ofItem: clientItem, withInfo: info)
    }

    /// This item when it stands for `clientItem`.
    @objc(itemForClientItem:)
    func item(forClientItem clientItem: AnyObject?) -> ECSBItem? {
        self.clientItem === clientItem ? self : nil
    }
}

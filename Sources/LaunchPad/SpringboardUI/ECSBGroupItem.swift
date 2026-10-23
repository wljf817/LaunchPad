import Foundation

/// A folder; its items are the folder's page items (research paper §6.1). Its `ECSBGroup` is made
/// with its item layer (research paper §11).
@MainActor
@objc(ECSBGroupItem)
class ECSBGroupItem: ECSBContainerItem {
    @objc weak var group: ECSBGroup?

    /// The item layer as it is, without checking its class, as the original returns it.
    @objc var groupItemLayer: ECSBGroupItemLayer? {
        get { unsafeBitCast(itemLayer, to: ECSBGroupItemLayer?.self) }
        set { itemLayer = newValue }
    }
}

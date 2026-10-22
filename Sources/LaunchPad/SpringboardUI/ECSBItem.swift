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
}

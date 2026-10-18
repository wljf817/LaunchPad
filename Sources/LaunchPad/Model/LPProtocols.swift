import Foundation

/// An item that holds other items: folders, pages and roots.
@objc(LPItemContainer)
protocol LPItemContainer: NSObjectProtocol {
    var children: NSMutableArray { get }
    var pagesOnly: Bool { get }
    var isEmpty: Bool { get }
}

/// An item the layout places and the exclude and game lists match.
@objc(LPLayoutItem)
protocol LPLayoutItem: NSObjectProtocol {
    var bundleIdentifier: String? { get }
    var excludeListName: String? { get }
    var isStoreApp: Bool { get }
    var addedByUser: Bool { get }
    var isRestricted: Bool { get set }
}

/// An object saved by `LPStorage` that is not an item.
@objc(LPStorageStorable)
protocol LPStorageStorable: NSObjectProtocol {
    var storage: LPStorage? { get set }
}

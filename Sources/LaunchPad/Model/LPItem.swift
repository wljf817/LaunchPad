import Foundation
import SQLite3

/// The base of everything in the Launchpad tree: apps, folders, pages and roots.
///
/// Thread confinement: the tree is changed on the main thread. Snapshots
/// (`snapshotForStorage:deepCopy:`) are handed to `LPStorage` and read only on its database queue.
/// Apps found by a scan are built on the scanning queue and handed to the main thread before they
/// join the tree.
@objc(LPItem)
class LPItem: NSObject, @unchecked Sendable {
    var _title: String?
    @objc var uuid: String?
    var _flags: UInt64 = 0
    var _isSparseCopy = false
    var _isSnapshot = false
    /// The icon and mini icon, `CGImage`s (REF-GRID-012).
    var _icon: AnyObject?
    var _miniIcon: AnyObject?
    var _shouldCacheIcons = false
    @objc weak var storage: LPStorage?
    @objc weak var parentContainer: (LPItem & LPItemContainer)?

    @objc(initWithTitle:)
    init(title: String?) {
        _title = title
        uuid = newUUIDString()
        super.init()
    }

    /// Decodes the columns from `column` on, starting with `uuid` and `flags`; advances `column`.
    @objc(initWithSQLStatement:withColumn:)
    required init?(sqlStatement statement: OpaquePointer, withColumn column: UnsafeMutablePointer<Int32>) {
        super.init()
        guard let text = sqlite3_column_text(statement, column.pointee) else {
            column.pointee += 1
            NSLog("ERROR %s requires a uuid", NSStringFromClass(type(of: self)))
            return nil
        }
        column.pointee += 1
        uuid = String(cString: text)
        _flags = UInt64(bitPattern: sqlite3_column_int64(statement, column.pointee))
        column.pointee += 1
    }

    /// The original's `-_initForCopy`: a bare object that `snapshotForStorage:deepCopy:` fills in.
    required init(forCopy: ()) {
        super.init()
    }

    /// A copy for the database queue. With `forStorage` it keeps the uuid and the icons, otherwise it
    /// gets a new uuid; without `deepCopy` it is marked sparse.
    @objc(snapshotForStorage:deepCopy:)
    func snapshotForStorage(_ forStorage: Bool, deepCopy: Bool) -> LPItem {
        let copy = type(of: self).init(forCopy: ())
        copy._title = _title
        copy._flags = _flags
        if forStorage {
            copy._icon = _icon
            copy._miniIcon = _miniIcon
        }
        copy.uuid = forStorage ? uuid : newUUIDString()
        if !deepCopy {
            copy._isSparseCopy = true
        }
        copy._isSnapshot = true
        return copy
    }

    /// Dynamic, so that setting it from Swift also reaches the observers (REF-GRID-014).
    @objc dynamic var title: String? {
        get { _title }
        set {
            if isEqualToString(_title, newValue) {
                return
            }
            _title = newValue
            updateTitleStorage()
        }
    }

    @objc var flags: UInt64 {
        get { _flags }
        set {
            guard _flags != newValue else { return }
            _flags = newValue
            updateFlagsStorage()
        }
    }

    /// Dynamic, so that setting it from Swift also reaches the observers (REF-GRID-014).
    @objc dynamic var icon: AnyObject? {
        get { _icon }
        set {
            willChangeValue(forKey: "icon")
            _icon = newValue
            didChangeValue(forKey: "icon")
        }
    }

    /// The original announces the change twice with `willChange` and never with `didChange`
    /// (research paper §12.4).
    @objc dynamic var miniIcon: AnyObject? {
        get { _miniIcon }
        set {
            willChangeValue(forKey: "miniIcon")
            _miniIcon = newValue
            willChangeValue(forKey: "miniIcon")
        }
    }

    @objc dynamic var iconForStorage: AnyObject? { icon }
    @objc dynamic var miniIconForStorage: AnyObject? { miniIcon }

    @objc var shouldCacheIcons: Bool {
        get { _shouldCacheIcons }
        set { _shouldCacheIcons = newValue }
    }

    @objc var isSparseCopy: Bool { _isSparseCopy }
    @objc var isSnapshot: Bool { _isSnapshot }

    @objc var isGroup: Bool { false }
    @objc var isApp: Bool { false }
    @objc var isRoot: Bool { false }
    @objc var isPage: Bool { false }

    /// The nearest folder above this item; pages do not count.
    @objc var parentGroup: LPGroup? {
        guard let parent = parentContainer else { return nil }
        if let group = parent as? LPGroup, !(parent is LPPage) {
            return group
        }
        return parent.parentGroup
    }

    /// The nearest page above this item.
    @objc var parentPage: LPPage? {
        guard let parent = parentContainer else { return nil }
        if let page = parent as? LPPage {
            return page
        }
        return parent.parentPage
    }

    /// The top of the tree this item is in, if that is a root.
    @objc var root: LPRoot? {
        var item: LPItem = self
        while let parent = item.parentContainer {
            item = parent
        }
        return item as? LPRoot
    }
}

// MARK: - LPStorage

extension LPItem {
    /// `items.type` of this kind of item (REF-LAYOUT-002).
    @objc var storageType: Int { 0 }

    /// The table that holds this kind of item's own columns.
    @objc var storageTable: String? { nil }

    /// The properties written when the item is inserted.
    @objc var storageCreationProperties: [String]? { nil }

    /// The column of `storageTable` that holds `property`.
    @objc func storageColumnForProperty(_ property: String) -> String? {
        ["title": "title"][property]
    }

    @objc func updateTitleStorage() {
        let snapshot = snapshotForStorage(true, deepCopy: false)
        weak let storage = storage
        storage?.addBlockToDatabaseQueue {
            storage?._updateItem(snapshot, withItemProperties: ["title"])
        }
    }

    /// Writes the icons of a snapshot to `image_cache` (REF-GRID-012).
    @objc func updateImageStorage() {
        weak let storage = storage
        let snapshot = snapshotForStorage(true, deepCopy: false)
        storage?.addBlockToDatabaseQueue {
            storage?._updateImageStorageForItem(snapshot)
        }
    }

    @objc func updateFlagsStorage() {
        weak let storage = storage
        let snapshot = snapshotForStorage(true, deepCopy: false)
        storage?.addBlockToDatabaseQueue {
            storage?._updateFlagsForItem(snapshot)
        }
    }

    /// Runs on the database queue, on a snapshot. `storage` is the `LPStorage`.
    @objc(insertIntoStorage:parent:withOrder:)
    func insertIntoStorage(_ storage: AnyObject, parent parentUUID: String, withOrder order: Int) {
        let storage = storage as! LPStorage
        let rowid = storage._insertItem(self, intoParent: parentUUID, withOrder: order)
        storage._insertItem(self, properties: storageCreationProperties, itemID: rowid)
    }

    @objc(insertNewChild:intoStorageWithOrder:)
    func insertNewChild(_ child: LPItem, intoStorageWithOrder order: Int) {
        weak let storage = storage
        precondition(conforms(to: LPItemContainer.self), "\(#function) is illegal for items which are not LPItemContainer")
        guard let current = storage, !current.loadingChildren else { return }
        let snapshot = child.snapshotForStorage(true, deepCopy: true)
        let parentUUID = uuid
        child.storage = current
        current.addBlockToDatabaseQueue {
            guard let storage, let parentUUID else { return }
            snapshot.insertIntoStorage(storage, parent: parentUUID, withOrder: order)
        }
    }

    @objc(reorderChild:inStorageOrder:)
    func reorderChild(_ child: LPItem, inStorageOrder order: Int) {
        weak let storage = storage
        precondition(conforms(to: LPItemContainer.self), "\(#function) is illegal for items which are not LPItemContainer")
        guard let current = storage else { return }
        let snapshot = child.snapshotForStorage(true, deepCopy: false)
        current.addBlockToDatabaseQueue {
            storage?._updateItem(snapshot, order: UInt(bitPattern: order))
        }
    }

    @objc(reparentChild:inStorageOrder:)
    func reparentChild(_ child: LPItem, inStorageOrder order: Int) {
        weak let storage = storage
        precondition(conforms(to: LPItemContainer.self), "\(#function) is illegal for items which are not LPItemContainer")
        guard let current = storage else { return }
        let snapshot = child.snapshotForStorage(true, deepCopy: false)
        let parentUUID = uuid
        current.addBlockToDatabaseQueue {
            storage?._updateItem(snapshot, parent: parentUUID, order: UInt(bitPattern: order))
        }
    }

    @objc(deleteChildFromStorage:)
    func deleteChildFromStorage(_ child: LPItem) {
        weak let storage = storage
        precondition(conforms(to: LPItemContainer.self), "\(#function) is illegal for items which are not LPItemContainer")
        guard let current = storage else { return }
        child.storage = nil
        let snapshot = child.snapshotForStorage(true, deepCopy: false)
        current.addBlockToDatabaseQueue {
            storage?._removeItem(snapshot)
        }
    }
}

/// `-[NSString isEqualToString:]` sent to `a`: false when either is nil.
func isEqualToString(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return false }
    return (a as NSString).isEqual(to: b)
}

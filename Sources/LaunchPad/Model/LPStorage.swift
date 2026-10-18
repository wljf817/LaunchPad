import Foundation
import LaunchPadPrivate
import SQLite3
import Synchronization

/// The Launchpad database (REF-LAYOUT-001, REF-LAYOUT-002).
///
/// Thread confinement: everything that touches `db` runs on `db_queue`: creating and reading the
/// database at init, and the blocks of committed transactions. Transactions are begun, filled and
/// committed on the main thread; `dbInfo` is changed on the main thread.
@objc(LPStorage)
final class LPStorage: NSObject, @unchecked Sendable {
    var currentDBReference: Int32 = 0
    var allowedDBReference: Int32 = 0
    let db_queue: DispatchQueue
    var db: OpaquePointer?
    let statement_cache: LPStorageStatementCache
    @objc let path: String
    var _localization: String?
    var _regionCode: String?
    var _build: String?
    var _dbInfo: NSMutableDictionary?
    var currentTransaction: LPStorageTransaction?
    var launchpadRootID: UInt64 = 0
    var launchpadOldVersionRootID: UInt64 = 0
    var launchpadRootPage: LPRoot?
    var launchpadOldVersionsPage: LPRoot?
    var categories = NSMapTable<NSString, NSNumber>.strongToStrongObjects()
    var appSources: NSMutableSet?
    var _loadingChildren = false
    var initalSetupComplete = false
    @objc let readOnly: Bool
    var _commitException: LPDatabaseException?

    /// Opens or creates the database at `path` on the database queue, reads both roots and the app
    /// sources, and passes them to `callback` on that queue. When that fails, the callback gets two
    /// empty roots and nothing is ever written.
    @objc(initWithPath:readOnly:retrievingExistingValues:)
    init(path: String, readOnly: Bool,
         retrievingExistingValues callback: @escaping @convention(block) (LPRoot?, LPRoot?, [LPAppSource]?) -> Void) {
        self.path = path
        self.readOnly = readOnly
        if readOnly {
            allowedDBReference = 1000
        }
        db_queue = DispatchQueue(label: "LPStorage Database Queue")
        statement_cache = LPStorageStatementCache(queue: db_queue)
        super.init()
        let callback = UncheckedBox(callback)
        db_queue.async { [self] in
            if _createDatabaseAtPath(path, failureReason: nil), _readInitalDatabaseStateFromPath(path, isInitial: true) {
                callback.value(launchpadRootPage, launchpadOldVersionsPage, appSources?.allObjects as? [LPAppSource])
            } else {
                NSLog("LPStorage: unable to open the database at %@", path)
                allowedDBReference = 10000
                let root = LPRoot()
                root.uuid = "ROOTPAGE"
                root.storage = self
                let versionsRoot = LPRoot()
                versionsRoot.uuid = "ROOTPAGE"
                versionsRoot.storage = self
                callback.value(root, versionsRoot, nil)
            }
        }
    }

    @objc var database: OpaquePointer? { db }
    @objc var loadingChildren: Bool { _loadingChildren }
    @objc var localization: String? { _localization }
    @objc var regionCode: String? { _regionCode }
    @objc var build: String? { _build }
    /// Nil for a database created by this process: the values are read only when opening one.
    @objc var dbInfo: NSDictionary? { _dbInfo }
    @objc var commitException: LPDatabaseException? { _commitException }

    /// The first of the user's preferred languages, read once per process.
    @objc class var currentLocalization: String? { cachedLocalization }
    private static let cachedLocalization = Locale.preferredLanguages.first

    /// The current locale's country code, read once per process.
    @objc class var currentRegionCode: String? { cachedRegionCode }
    private static let cachedRegionCode = (Locale.current as NSLocale).countryCode

    // MARK: Transactions

    @objc func beginTransaction() -> String {
        precondition(currentTransaction == nil, "startTransaction called while another transaction is active. This is invalid")
        let transaction = LPStorageTransaction(databaseReference: currentDBReference)
        currentTransaction = transaction
        return transaction.uuid
    }

    /// Runs the transaction's blocks on the database queue inside one SQL transaction, unless the
    /// database it was begun for is no longer the allowed one.
    @objc(commitTransaction:)
    func commitTransaction(_ uuid: String?) {
        let reference = currentDBReference
        let transaction = currentTransaction
        currentTransaction = nil
        guard let uuid, let transaction, (transaction.uuid as NSString).isEqual(to: uuid) else {
            NSLog("LPStorage: commitTransaction: with a transaction that is not the current one")
            return
        }
        db_queue.async { [self] in
            guard reference == allowedDBReference, transaction.dbref == allowedDBReference, let db else {
                NSLog("LPStorage: dropping a transaction for a database that is not current")
                return
            }
            if sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK {
                for block in transaction.blocks {
                    unsafeBitCast(block as AnyObject, to: (@convention(block) () -> Void).self)()
                    if _commitException != nil {
                        break
                    }
                }
                if _commitException == nil {
                    sqlite3_exec(db, "COMMIT", nil, nil, nil)
                }
            }
            if let exception = _commitException {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                NSLog("LPStorage: transaction failed: %@", exception.description)
                _commitException = nil
                // The original recreates the database here (design, omitted cases).
            }
        }
    }

    @objc(dropTransaction:)
    func dropTransaction(_ uuid: String?) {
        if let uuid, let transaction = currentTransaction, (transaction.uuid as NSString).isEqual(to: uuid) {
            currentTransaction = nil
        }
    }

    /// Adds the block to the open transaction, or runs it in a transaction of its own.
    @objc(addBlockToDatabaseQueue:)
    func addBlockToDatabaseQueue(_ block: @escaping @convention(block) () -> Void) {
        if let transaction = currentTransaction {
            transaction.addBlock(block)
        } else {
            let uuid = beginTransaction()
            currentTransaction?.addBlock(block)
            commitTransaction(uuid)
        }
    }

    // MARK: dbinfo

    @objc func markInitialSetupComplete() {
        weak let storage = self
        addBlockToDatabaseQueue {
            storage?._markComplete()
        }
    }

    @objc func _markComplete() {
        initalSetupComplete = true
        _removeDBInfoForKey("setup_incomplete")
    }

    /// Sets a `dbinfo` row; nil removes it. The value in `dbInfo` changes at once.
    @objc(setDBInfoValue:forKey:)
    func setDBInfoValue(_ value: Any?, forKey key: String) {
        weak let storage = self
        if let value {
            let existed = _dbInfo?[key] != nil
            _dbInfo?[key] = value
            let box = UncheckedBox(value)
            addBlockToDatabaseQueue {
                storage?._setDBInfoValue(box.value, forKey: key, existed: existed)
            }
        } else {
            _dbInfo?.removeObject(forKey: key)
            addBlockToDatabaseQueue {
                storage?._removeDBInfoForKey(key)
            }
        }
    }

    @objc(_setDBInfoValue:forKey:existed:)
    @discardableResult
    func _setDBInfoValue(_ value: Any?, forKey key: String, existed: Bool) -> Bool {
        let sql = existed ? "UPDATE dbinfo SET value=? WHERE key=?;" : "INSERT INTO dbinfo (value,key) VALUES (?,?);"
        var statement: OpaquePointer?
        var result = statement_cache.statement(with: sql, database: db, statement: &statement)
        if result == SQLITE_OK {
            result = bindObject(statement, 1, value)
        }
        if result == SQLITE_OK {
            result = bindString(statement, 2, key)
        }
        if result == SQLITE_OK {
            result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                return true
            }
        }
        recordFailure(#function, #line, result)
        return false
    }

    @objc(_removeDBInfoForKey:)
    func _removeDBInfoForKey(_ key: String) {
        let sql = "DELETE FROM dbinfo WHERE key=?"
        var statement: OpaquePointer?
        var result = statement_cache.statement(with: sql, database: db, statement: &statement)
        if result == SQLITE_OK {
            result = bindString(statement, 1, key)
        }
        if result == SQLITE_OK {
            result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                return
            }
        }
        recordFailure(#function, #line, result)
    }

    /// Reads every `dbinfo` row; a missing `version` reads as 4 (REF-LAYOUT-002).
    @objc(_dbInfo:failure:)
    func _dbInfo(_ db: OpaquePointer?, failure: AutoreleasingUnsafeMutablePointer<LPDatabaseException?>?) -> NSMutableDictionary? {
        var info: NSMutableDictionary? = NSMutableDictionary(capacity: 0)
        var statement: OpaquePointer?
        var result = sqlite3_prepare_v2(db, "SELECT * FROM dbinfo", -1, &statement, nil)
        if result == SQLITE_OK {
            result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                let key = columnString(statement, 0)
                let value: Any?
                switch sqlite3_column_type(statement, 1) {
                case SQLITE_INTEGER: value = NSNumber(value: sqlite3_column_int64(statement, 1))
                case SQLITE_FLOAT: value = NSNumber(value: sqlite3_column_double(statement, 1))
                case SQLITE_TEXT: value = columnString(statement, 1)
                case SQLITE_BLOB:
                    value = NSData(bytes: sqlite3_column_blob(statement, 1), length: Int(sqlite3_column_bytes(statement, 1)))
                case SQLITE_NULL: value = NSNull()
                default: value = nil
                }
                if let key, let value {
                    info?[key] = value
                }
                result = sqlite3_step(statement)
            }
        }
        if result != SQLITE_DONE {
            failure?.pointee = LPDatabaseException(exceptionInMethod: #function, lineNumber: #line, database: db, ret: result)
            info = nil
        }
        sqlite3_finalize(statement)
        if info?["version"] == nil {
            info?["version"] = 4
        }
        return info
    }

    // MARK: Creating and opening

    /// Removes the database directory and creates it again, empty.
    @objc(_deleteOldDatabaseAtPath:)
    func _deleteOldDatabaseAtPath(_ path: String) -> Bool {
        let directory = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.removeItem(atPath: directory)
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            return true
        } catch {
            NSLog("LPStorage: unable to delete the old database: %@", String(describing: error))
            return false
        }
    }

    /// Opens the database at `path` and checks its `dbinfo`, or creates a new one (REF-LAYOUT-002).
    /// A database that cannot be opened or must be discarded is deleted and created again; the new
    /// one records `reason`.
    @objc(_createDatabaseAtPath:failureReason:)
    func _createDatabaseAtPath(_ path: String?, failureReason reason: String?) -> Bool {
        guard let path else { return false }
        var fileStatus = stat()
        let exists = stat(path, &fileStatus) == 0
        var database: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let openResult = sqlite3_open_v2(path, &database, flags, nil)
        guard openResult == SQLITE_OK else {
            if !readOnly, FileManager.default.fileExists(atPath: path), _deleteOldDatabaseAtPath(path) {
                let reason = String(format: "%@ %ld Database failed sqlite3_open returned %d", #function, #line, openResult)
                return _createDatabaseAtPath(path, failureReason: reason)
            }
            return false
        }

        if exists {
            var error: LPDatabaseException?
            let info = _dbInfo(database, failure: &error)
            let version = (info?["version"] as AnyObject?)?.integerValue ?? 0
            let compatibleVersion = (info?["compatibleVersion"] as AnyObject?)?.integerValue ?? 0
            let setupIncomplete = (info?["setup_incomplete"] as AnyObject?)?.boolValue ?? false
            let appsManaged = (info?["apps_managed"] as AnyObject?)?.boolValue ?? false
            var discardReason: String?
            var keep = false
            if let info, error == nil {
                if !(4...13).contains(compatibleVersion) {
                    NSLog("LPStorage: incompatible database version %ld", compatibleVersion)
                } else if version < 13 {
                    // Upgrading older databases is not done (design, omitted cases).
                } else if setupIncomplete {
                    NSLog("LPStorage: the last setup did not complete")
                } else {
                    launchpadRootID = UInt64(bitPattern: Int64((info["launchpad_root"] as AnyObject?)?.integerValue ?? 0))
                    if let versionRoot = info["launchpad_version_root"] as AnyObject? {
                        launchpadOldVersionRootID = UInt64(bitPattern: Int64(versionRoot.integerValue))
                    } else {
                        launchpadOldVersionRootID = UInt64(Int.max)
                    }
                    if !appsManaged {
                        _localization = info["localization"] as? String
                        _regionCode = info["region_code"] as? String
                        _build = info["build"] as? String
                        _dbInfo = info.mutableCopy() as? NSMutableDictionary
                        initalSetupComplete = !setupIncomplete
                        keep = true
                    }
                }
            } else {
                discardReason = error?.description
            }
            if !keep {
                if appsManaged {
                    NSLog("Switching LaunchPad from Simple Finder.")
                }
                statement_cache.clearStatements()
                sqlite3_close(database)
                if !readOnly, _deleteOldDatabaseAtPath(path) {
                    return _createDatabaseAtPath(path, failureReason: discardReason)
                }
                return false
            }
        } else {
            guard sqlite3_exec(database, "PRAGMA journal_mode = WAL", nil, nil, nil) == SQLITE_OK else {
                return false
            }
            _build = (_CFCopySystemVersionDictionary()?.takeRetainedValue() as NSDictionary?)?[_kCFSystemVersionBuildVersionKey as String] as? String
            _localization = LPStorage.currentLocalization
            _regionCode = LPStorage.currentRegionCode
            let sql = Self.creationSQL
                + "INSERT INTO dbinfo (key, value) VALUES ('compatibleVersion', 6);\n"
                + "INSERT INTO dbinfo (key, value) VALUES ('version', 13);\n"
                + "INSERT INTO dbinfo (key, value) VALUES ('build', '\(sqlText(_build ?? "NULL"))');\n"
                + "INSERT INTO dbinfo (key, value) VALUES ('localization', '\(sqlText(_localization ?? ""))');\n"
                + "INSERT INTO dbinfo (key, value) VALUES ('region_code', '\(sqlText(_regionCode ?? ""))');\n"
                + "INSERT INTO dbinfo (key, value) VALUES ('curateListVersionLP', '1');\n"
                + "INSERT INTO dbinfo (key, value) VALUES ('excludeListVersionLP', '3');\n"
                + "INSERT INTO dbinfo (key, value) VALUES ('includeAsGameListVersionLP', '1');\n"
                + "COMMIT;\n"
            launchpadOldVersionRootID = 5
            launchpadRootID = 1
            let result = sqlite3_exec(database, sql, nil, nil, nil)
            guard result == SQLITE_OK else {
                NSLog("Unable to initialize new database %d (%s)", result, sqlite3_errmsg(database))
                sqlite3_close(database)
                return false
            }
        }

        db = database
        if let reason {
            _setDBInfoValue(reason, forKey: "failureReason", existed: false)
            _setDBInfoValue(Date().description, forKey: "failureLastDate", existed: false)
        }
        return true
    }

    /// A new database (REF-LAYOUT-002): the tables, indexes and triggers, the first `dbinfo` rows
    /// and the fixed items. The caller appends the remaining `dbinfo` rows and the `COMMIT`.
    private static let creationSQL = """
        BEGIN EXCLUSIVE;
        CREATE TABLE dbinfo (key VARCHAR, value VARCHAR);
        CREATE TABLE items (rowid INTEGER PRIMARY KEY ASC, uuid VARCHAR, flags INTEGER, type INTEGER, parent_id INTEGER NOT NULL, ordering INTEGER);
        CREATE TABLE apps (item_id INTEGER PRIMARY KEY, title VARCHAR, bundleid VARCHAR, storeid VARCHAR, category_id INTEGER, moddate REAL, bookmark BLOB);
        CREATE TABLE groups (item_id INTEGER PRIMARY KEY, category_id INTEGER, title VARCHAR);
        CREATE TABLE downloading_apps (item_id INTEGER PRIMARY KEY, title VARCHAR, bundleid VARCHAR, storeid VARCHAR, category_id INTEGER, install_path VARCHAR);
        CREATE TABLE categories (rowid INTEGER PRIMARY KEY ASC, uti VARCHAR);
        CREATE TABLE app_sources (rowid INTEGER PRIMARY KEY ASC, uuid VARCHAR, flags INTEGER, bookmark BLOB, last_fsevent_id INTEGER, fsevent_uuid VARCHAR);
        CREATE TABLE image_cache (item_id INTEGER, size_big INTEGER, size_mini INTEGER, image_data BLOB, image_data_mini BLOB);

        CREATE TRIGGER update_items_order BEFORE UPDATE OF ordering ON items
        WHEN new.ordering > old.ordering AND 0 == (SELECT value FROM dbinfo WHERE key = 'ignore_items_update_triggers')
        BEGIN
            UPDATE dbinfo SET value = 1 WHERE key = 'ignore_items_update_triggers';
            UPDATE items SET ordering = ordering - 1
                WHERE parent_id = old.parent_id AND ordering BETWEEN old.ordering AND new.ordering;
            UPDATE dbinfo SET value = 0 WHERE key = 'ignore_items_update_triggers';
        END;

        CREATE TRIGGER update_items_order_backwards BEFORE UPDATE OF ordering ON items
        WHEN new.ordering < old.ordering AND 0 == (SELECT value FROM dbinfo WHERE key = 'ignore_items_update_triggers')
        BEGIN
            UPDATE dbinfo SET value = 1 WHERE key = 'ignore_items_update_triggers';
            UPDATE items SET ordering = ordering + 1
                WHERE parent_id = old.parent_id AND ordering BETWEEN new.ordering AND old.ordering;
            UPDATE dbinfo SET value = 0 WHERE key = 'ignore_items_update_triggers';
        END;

        CREATE TRIGGER update_item_parent AFTER UPDATE OF parent_id ON items
        WHEN 0 == (SELECT value FROM dbinfo WHERE key = 'ignore_items_update_triggers')
        BEGIN
            UPDATE dbinfo SET value = 1 WHERE key = 'ignore_items_update_triggers';
            UPDATE items SET ordering = (SELECT ifnull(MAX(ordering), 0) + 1 FROM items WHERE parent_id = new.parent_id AND rowid != old.rowid)
                WHERE rowid = old.rowid;
            UPDATE items SET ordering = ordering - 1 WHERE parent_id = old.parent_id AND ordering > old.ordering;
            UPDATE dbinfo SET value = 0 WHERE key = 'ignore_items_update_triggers';
        END;

        CREATE TRIGGER insert_item AFTER INSERT ON items
        WHEN 0 == (SELECT value FROM dbinfo WHERE key = 'ignore_items_update_triggers')
        BEGIN
            UPDATE dbinfo SET value = 1 WHERE key = 'ignore_items_update_triggers';
            UPDATE items SET ordering = (SELECT ifnull(MAX(ordering), 0) + 1 FROM items WHERE parent_id = new.parent_id)
                WHERE rowid = new.rowid;
            UPDATE dbinfo SET value = 0 WHERE key = 'ignore_items_update_triggers';
        END;

        CREATE TRIGGER app_inserted AFTER INSERT ON items
        WHEN new.type = 4 OR new.type = 5
        BEGIN
            INSERT INTO image_cache VALUES (new.rowid, 0, 0, NULL, NULL);
        END;

        CREATE TRIGGER app_deleted AFTER DELETE ON items
        WHEN old.type = 4 OR old.type = 5
        BEGIN
            DELETE FROM image_cache WHERE item_id = old.rowid;
        END;

        CREATE TRIGGER item_deleted AFTER DELETE ON items
        BEGIN
            DELETE FROM apps WHERE rowid = old.rowid;
            DELETE FROM groups WHERE item_id = old.rowid;
            DELETE FROM downloading_apps WHERE item_id = old.rowid;
            UPDATE dbinfo SET value = 1 WHERE key = 'ignore_items_update_triggers';
            UPDATE items SET ordering = ordering - 1 WHERE parent_id = old.parent_id AND ordering > old.ordering;
            UPDATE dbinfo SET value = 0 WHERE key = 'ignore_items_update_triggers';
        END;

        CREATE INDEX items_uuid_index ON items (uuid);
        CREATE INDEX items_ordering_index ON items (parent_id, ordering);
        CREATE INDEX items_type ON items (type);
        CREATE INDEX image_cache_index ON image_cache (item_id);

        INSERT INTO dbinfo (key, value) VALUES ('ignore_items_update_triggers', 0);
        INSERT INTO dbinfo (key, value) VALUES ('setup_incomplete', 1);
        UPDATE dbinfo SET value = 1 WHERE key = 'ignore_items_update_triggers';
        INSERT INTO items (rowid, uuid, parent_id, type, ordering) VALUES (1, 'ROOTPAGE', 0, 1, 0);
        INSERT INTO groups (item_id) VALUES (1);
        INSERT INTO dbinfo (key, value) VALUES ('launchpad_root', 1);
        INSERT INTO items (rowid, uuid, parent_id, type, ordering) VALUES (2, 'HOLDINGPAGE', 1, 3, 0);
        INSERT INTO groups (item_id) VALUES (2);
        INSERT INTO items (rowid, uuid, parent_id, type, ordering) VALUES (4, 'HOLDINGPAGE_DB', 3, 3, 0);
        INSERT INTO groups (item_id) VALUES (4);
        INSERT INTO items (rowid, uuid, parent_id, type, ordering) VALUES (5, 'ROOTPAGE_VERS', 0, 1, 0);
        INSERT INTO groups (item_id) VALUES (5);
        INSERT INTO dbinfo (key, value) VALUES ('launchpad_version_root', 5);
        INSERT INTO items (rowid, uuid, parent_id, type, ordering) VALUES (6, 'HOLDINGPAGE_VERS', 5, 3, 0);
        INSERT INTO groups (item_id) VALUES (6);
        UPDATE dbinfo SET value = 0 WHERE key = 'ignore_items_update_triggers';

        """

    // MARK: Reading

    @objc(_readInitalDatabaseStateFromPath:isInitial:)
    func _readInitalDatabaseStateFromPath(_ path: String, isInitial: Bool) -> Bool {
        _readAllCategories()
        appSources = nil
        _readAppSourcesFromDBForType(4)
        _readAllItemObjects()
        _doDatabaseValidation()
        return true
    }

    @objc func _readAllCategories() {
        categories = NSMapTable<NSString, NSNumber>.strongToStrongObjects()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT * FROM categories", -1, &statement, nil) == SQLITE_OK else { return }
        while sqlite3_step(statement) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(statement, 0)
            if let uti = columnString(statement, 1) {
                categories.setObject(NSNumber(value: rowid), forKey: uniqueCategoryString(uti) as NSString)
            }
        }
        sqlite3_finalize(statement)
    }

    /// Only type 4, the table `app_sources`, exists.
    @objc(_readAppSourcesFromDBForType:)
    func _readAppSourcesFromDBForType(_ type: Int) {
        guard type == 4 else { return }
        if appSources == nil {
            appSources = NSMutableSet(capacity: 0)
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT uuid,flags,last_fsevent_id,fsevent_uuid FROM app_sources", -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let source = LPAppSource(sqlStatement: statement) {
                source.storage = self
                appSources?.add(source)
            }
        }
        sqlite3_finalize(statement)
    }

    /// Loads apps, folders, pages and roots, then their child relationships. A failure is raised and
    /// nothing catches it, as in the original.
    @objc func _readAllItemObjects() {
        let items = NSMapTable<NSNumber, LPItem>.strongToStrongObjects()
        let apps = "SELECT apps.item_id, items.uuid, items.flags, apps.title, apps.storeid, apps.moddate, apps.bookmark, "
            + "categories.uti, image_cache.size_big, image_cache.image_data, image_cache.size_mini, image_cache.image_data_mini, apps.bundleid "
            + "FROM apps JOIN items ON apps.rowid = items.rowid JOIN image_cache ON apps.rowid = image_cache.item_id "
            + "LEFT JOIN categories ON apps.category_id = categories.rowid"
        let groups = "SELECT groups.item_id, items.uuid, items.flags, groups.title FROM groups JOIN items ON groups.rowid = items.rowid WHERE items.type = %ld;"
        _loadItem(withQuery: apps, with: LPApp.self, intoTable: items)
        // Downloading apps are read here in the original (phase 6).
        _loadItem(withQuery: String(format: groups, 2), with: LPGroup.self, intoTable: items)
        _loadItem(withQuery: String(format: groups, 3), with: LPPage.self, intoTable: items)
        _loadItem(withQuery: String(format: groups, 1), with: LPRoot.self, intoTable: items)
        if let exception = _commitException {
            exception.raise()
        }
        _loadChildRelationshipsWithItems(items)
        if let exception = _commitException {
            exception.raise()
        }
    }

    @objc(_loadItemWithQuery:withClass:intoTable:)
    func _loadItem(withQuery query: String, with itemClass: AnyClass, intoTable table: NSMapTable<NSNumber, LPItem>) {
        guard let itemClass = itemClass as? LPItem.Type else { return }
        var statement: OpaquePointer?
        var result = sqlite3_prepare_v2(db, query, -1, &statement, nil)
        if result == SQLITE_OK, let statement {
            result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                let rowid = sqlite3_column_int64(statement, 0)
                var column: Int32 = 1
                guard let item = itemClass.init(sqlStatement: statement, withColumn: &column) else {
                    result = SQLITE_ERROR
                    break
                }
                item.storage = self
                table.setObject(item, forKey: NSNumber(value: rowid))
                result = sqlite3_step(statement)
            }
        }
        sqlite3_finalize(statement)
        if result != SQLITE_DONE {
            _commitException = LPDatabaseException(exceptionInMethod: #function, lineNumber: #line, database: db, ret: result)
        }
    }

    /// Attaches every item to its parent in `ordering` order. Parents whose stored orderings have
    /// gaps or repeats are fixed in the database (with the original's swapped parameters).
    @objc(_loadChildRelationshipsWithItems:)
    func _loadChildRelationshipsWithItems(_ items: NSMapTable<NSNumber, LPItem>) {
        var statement: OpaquePointer?
        var result = sqlite3_prepare_v2(db, "SELECT ROWID,parent_id, ordering FROM items ORDER BY parent_id,ordering", -1, &statement, nil)
        _loadingChildren = true
        if result == SQLITE_OK {
            let badParents = NSMutableSet()
            let orderingFixes = NSMapTable<NSNumber, NSNumber>.strongToStrongObjects()
            let children = NSMutableArray()
            var parent: LPItem?
            var parentID: Int64 = 0
            result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                let rowid = sqlite3_column_int64(statement, 0)
                let rowParentID = sqlite3_column_int64(statement, 1)
                let ordering = sqlite3_column_int64(statement, 2)
                if rowParentID == 0 {
                    if UInt64(bitPattern: rowid) == launchpadRootID {
                        launchpadRootPage = items.object(forKey: NSNumber(value: UInt64(bitPattern: rowid))) as? LPRoot
                    } else if UInt64(bitPattern: rowid) == launchpadOldVersionRootID {
                        launchpadOldVersionsPage = items.object(forKey: NSNumber(value: UInt64(bitPattern: rowid))) as? LPRoot
                    } else {
                        NSLog("Unexpected root level page found %lld", rowid)
                    }
                } else {
                    if parent == nil || parentID != rowParentID {
                        if let parent {
                            Self.attach(children, to: parent)
                        }
                        children.removeAllObjects()
                        parent = items.object(forKey: NSNumber(value: rowParentID))
                        parentID = rowParentID
                    }
                    if let child = items.object(forKey: NSNumber(value: rowid)) {
                        if let parent, ordering != Int64(children.count) {
                            orderingFixes.setObject(NSNumber(value: children.count), forKey: NSNumber(value: rowid))
                            badParents.add(parent)
                        }
                        children.add(child)
                    }
                }
                result = sqlite3_step(statement)
            }
            if result == SQLITE_DONE {
                if let parent {
                    Self.attach(children, to: parent)
                }
                if badParents.count != 0 {
                    for parent in badParents {
                        NSLog("%@ has bad children layout. Fixing.", String(describing: parent))
                    }
                    _fixupOrderingIssues(orderingFixes)
                }
            }
        }
        if result != SQLITE_DONE {
            _commitException = LPDatabaseException(exceptionInMethod: #function, lineNumber: #line, database: db, ret: result)
        }
        _loadingChildren = false
        sqlite3_finalize(statement)
    }

    /// Roots take the children as their raw children (hidden page included); others append them.
    private static func attach(_ children: NSMutableArray, to parent: LPItem) {
        guard children.count != 0 else { return }
        if let root = parent as? LPRoot {
            root.setRawChildren(children as! [Any])
        } else if let container = parent as? LPItemContainer {
            container.children.addObjects(from: children as! [Any])
        }
    }

    /// Writes the corrected orderings. The original binds each pair the wrong way round: the
    /// ordering gets the item's rowid and the rowid gets the correct ordering (research paper §16).
    @objc(_fixupOrderingIssues:)
    func _fixupOrderingIssues(_ fixes: NSMapTable<NSNumber, NSNumber>) {
        var result = sqlite3_exec(db, "BEGIN", nil, nil, nil)
        if result == SQLITE_OK {
            result = sqlite3_exec(db, "UPDATE dbinfo SET value=1 WHERE key='ignore_items_update_triggers'", nil, nil, nil)
        }
        if result == SQLITE_OK {
            var statement: OpaquePointer?
            result = statement_cache.statement(with: "UPDATE items SET ordering=? WHERE ROWID=?", database: db, statement: &statement)
            if result == SQLITE_OK {
                let enumerator = fixes.keyEnumerator()
                while let rowid = enumerator.nextObject() as? NSNumber {
                    let ordering = fixes.object(forKey: rowid)
                    sqlite3_reset(statement)
                    result = bindObject(statement, 1, rowid)
                    if result == SQLITE_OK {
                        result = bindObject(statement, 2, ordering)
                    }
                    if result == SQLITE_OK {
                        result = sqlite3_step(statement)
                        if result == SQLITE_DONE {
                            result = SQLITE_OK
                        }
                    }
                    if result != SQLITE_OK {
                        break
                    }
                }
            }
        }
        if result == SQLITE_OK {
            result = sqlite3_exec(db, "UPDATE dbinfo SET value=0 WHERE key='ignore_items_update_triggers'", nil, nil, nil)
        }
        if result == SQLITE_OK {
            result = sqlite3_exec(db, "COMMIT", nil, nil, nil)
        }
        if result != SQLITE_OK {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            _commitException = LPDatabaseException(exceptionInMethod: #function, lineNumber: #line, database: db, ret: result)
        }
    }

    /// Both roots must exist and hold only pages; otherwise an exception is raised that nothing
    /// catches.
    @objc func _doDatabaseValidation() {
        guard let root = launchpadRootPage, let versionsRoot = launchpadOldVersionsPage else {
            NSException(name: NSExceptionName("DatabaseValidation"), reason: "Missing root pages").raise()
            return
        }
        if root.storageChildren.contains(where: { !($0 is LPPage) }) {
            NSException(name: NSExceptionName("DatabaseValidation"), reason: "Launchpad root has non-pages").raise()
        }
        if versionsRoot.storageChildren.contains(where: { !($0 is LPPage) }) {
            NSException(name: NSExceptionName("DatabaseValidation"), reason: "LaunchPad versions root has non-pages").raise()
        }
    }

    // MARK: App sources

    /// Inserts the row of a source that has no storage yet.
    @objc(registerAppSourceWithStorage:)
    func registerAppSourceWithStorage(_ source: LPAppSource) {
        guard source.storage == nil else { return }
        let table = source.sourceTableName
        let properties = source.storageCreationDictionary
        if appSources == nil {
            appSources = NSMutableSet(capacity: 0)
        }
        appSources?.add(source)
        source.storage = self
        addBlockToDatabaseQueue { [self] in
            _insertRow(intoTable: table, withProperties: properties)
        }
    }

    @objc(_updateAppSource:properties:inTable:)
    @discardableResult
    func _updateAppSource(_ uuid: String, properties: [String: Any], inTable table: String) -> Bool {
        let columns = Array(properties.keys)
        let sql = "UPDATE \(table) SET " + columns.map { "\($0)=?" }.joined(separator: ", ") + " WHERE uuid=?"
        var statement: OpaquePointer?
        var result = statement_cache.statment(withNSString: sql, database: db, statement: &statement)
        if result == SQLITE_OK {
            var index: Int32 = 1
            for column in columns {
                result = bindObject(statement, index, properties[column])
                if result != SQLITE_OK {
                    NSLog("Failed to bind key=%@ value=%@ during UPDATE of %@", column, String(describing: properties[column]), table)
                    break
                }
                index += 1
            }
            if result == SQLITE_OK {
                result = bindString(statement, index, uuid)
            }
            if result == SQLITE_OK {
                result = sqlite3_step(statement)
                if result == SQLITE_DONE {
                    return true
                }
            }
        }
        recordFailure(#function, #line, result)
        return false
    }

    // MARK: Writing items

    /// Inserts one row; returns its rowid, or 0 on failure.
    @objc(_insertRowIntoTable:withProperties:)
    @discardableResult
    func _insertRow(intoTable table: String, withProperties properties: [String: Any]) -> Int64 {
        let columns = Array(properties.keys)
        let sql = "INSERT INTO \(table) (" + columns.joined(separator: ", ") + ") VALUES ("
            + columns.map { _ in "?" }.joined(separator: ", ") + ")"
        var statement: OpaquePointer?
        var result = statement_cache.statment(withNSString: sql, database: db, statement: &statement)
        if result == SQLITE_OK {
            var index: Int32 = 1
            for column in columns {
                result = bindObject(statement, index, properties[column])
                if result != SQLITE_OK {
                    NSLog("Failed to bind key=%@ value=%@ during INSERT into %@", column, String(describing: properties[column]), table)
                    break
                }
                index += 1
            }
            if result == SQLITE_OK {
                result = sqlite3_step(statement)
                if result == SQLITE_DONE {
                    return sqlite3_last_insert_rowid(db)
                }
            }
        }
        recordFailure(#function, #line, result)
        return 0
    }

    /// Column name → value for each property; a nil value is `NSNull`.
    @objc(_dictionaryForItem:properties:)
    func _dictionary(forItem item: LPItem, properties: [String]) -> [String: Any] {
        var dictionary: [String: Any] = [:]
        for property in properties {
            if let column = item.storageColumnForProperty(property) {
                dictionary[column] = item.value(forKey: property) ?? NSNull()
            }
        }
        return dictionary
    }

    @objc(_insertItem:properties:itemID:)
    @discardableResult
    func _insertItem(_ item: LPItem, properties: [String]?, itemID: Int64) -> Bool {
        guard let table = item.storageTable else { return false }
        var values = _dictionary(forItem: item, properties: properties ?? [])
        values["item_id"] = NSNumber(value: itemID)
        return _insertRow(intoTable: table, withProperties: values) != 0
    }

    /// Inserts the `items` row under the parent with `parentUUID` and moves it to `order`; returns
    /// its rowid.
    @objc(_insertItem:intoParent:withOrder:)
    func _insertItem(_ item: LPItem, intoParent parentUUID: String, withOrder order: Int) -> Int64 {
        let sql = "INSERT INTO items (uuid,flags,type,parent_id) VALUES (?, ?, ?, (SELECT rowid FROM items WHERE uuid=?))"
        var statement: OpaquePointer?
        var result = statement_cache.statement(with: sql, database: db, statement: &statement)
        if result == SQLITE_OK { result = bindString(statement, 1, item.uuid) }
        if result == SQLITE_OK { result = sqlite3_bind_int64(statement, 2, Int64(bitPattern: item.flags)) }
        if result == SQLITE_OK { result = sqlite3_bind_int64(statement, 3, Int64(item.storageType)) }
        if result == SQLITE_OK { result = bindString(statement, 4, parentUUID) }
        if result == SQLITE_OK {
            result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                let rowid = sqlite3_last_insert_rowid(db)
                var orderStatement: OpaquePointer?
                result = statement_cache.statement(with: "UPDATE items SET ordering=? WHERE rowid=?", database: db, statement: &orderStatement)
                if result == SQLITE_OK { result = sqlite3_bind_int64(orderStatement, 1, Int64(order)) }
                if result == SQLITE_OK { result = sqlite3_bind_int64(orderStatement, 2, rowid) }
                if result == SQLITE_OK {
                    result = sqlite3_step(orderStatement)
                    if result == SQLITE_DONE {
                        return rowid
                    }
                }
            }
        }
        recordFailure(#function, #line, result)
        return 0
    }

    @objc(_updateItem:withColumnValues:)
    @discardableResult
    func _updateItem(_ item: LPItem, withColumnValues values: [String: Any]) -> Bool {
        guard let table = item.storageTable else { return false }
        let columns = Array(values.keys)
        let sql = "UPDATE \(table) SET " + columns.map { "\($0)=?" }.joined(separator: ", ")
            + " WHERE item_id IN (SELECT rowid FROM items WHERE uuid=?);"
        var statement: OpaquePointer?
        var result = statement_cache.statment(withNSString: sql, database: db, statement: &statement)
        if result == SQLITE_OK {
            var index: Int32 = 1
            for column in columns {
                result = bindObject(statement, index, values[column])
                if result != SQLITE_OK {
                    NSLog("Failed to bind key=%@ value=%@ during UPDATE of %@", column, String(describing: values[column]), table)
                    break
                }
                index += 1
            }
            if result == SQLITE_OK {
                result = bindString(statement, index, item.uuid)
            }
            if result == SQLITE_OK {
                result = sqlite3_step(statement)
                if result == SQLITE_DONE {
                    return true
                }
            }
        }
        recordFailure(#function, #line, result)
        return false
    }

    @objc(_updateItem:withItemProperties:)
    @discardableResult
    func _updateItem(_ item: LPItem, withItemProperties properties: [String]) -> Bool {
        _updateItem(item, withColumnValues: _dictionary(forItem: item, properties: properties))
    }

    @objc(_updateItem:order:)
    @discardableResult
    func _updateItem(_ item: LPItem, order: UInt) -> Bool {
        var statement: OpaquePointer?
        var result = statement_cache.statement(with: "UPDATE items SET ordering=? WHERE uuid=?", database: db, statement: &statement)
        if result == SQLITE_OK { result = sqlite3_bind_int64(statement, 1, Int64(bitPattern: UInt64(order))) }
        if result == SQLITE_OK { result = bindString(statement, 2, item.uuid) }
        if result == SQLITE_OK {
            result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                return true
            }
        }
        recordFailure(#function, #line, result)
        return false
    }

    /// Moves the row under the parent with `parentUUID` (the trigger puts it last) and then to `order`.
    @objc(_updateItem:parent:order:)
    @discardableResult
    func _updateItem(_ item: LPItem, parent parentUUID: String?, order: UInt) -> Bool {
        let sql = "UPDATE items SET ordering=NULL, parent_id=(SELECT rowid FROM items WHERE uuid=?) WHERE uuid=?"
        var statement: OpaquePointer?
        var result = statement_cache.statement(with: sql, database: db, statement: &statement)
        if result == SQLITE_OK { result = bindString(statement, 1, parentUUID) }
        if result == SQLITE_OK { result = bindString(statement, 2, item.uuid) }
        if result == SQLITE_OK {
            result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                return _updateItem(item, order: order)
            }
        }
        recordFailure(#function, #line, result)
        return false
    }

    @objc(_updateFlagsForItem:)
    @discardableResult
    func _updateFlagsForItem(_ item: LPItem) -> Bool {
        var statement: OpaquePointer?
        var result = statement_cache.statement(with: "UPDATE items SET flags=? WHERE uuid=?", database: db, statement: &statement)
        if result == SQLITE_OK { result = sqlite3_bind_int64(statement, 1, Int64(bitPattern: item.flags)) }
        if result == SQLITE_OK { result = bindString(statement, 2, item.uuid) }
        if result == SQLITE_OK {
            result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                return true
            }
        }
        recordFailure(#function, #line, result)
        return false
    }

    @objc(_removeItem:)
    func _removeItem(_ item: LPItem) {
        var statement: OpaquePointer?
        var result = statement_cache.statement(with: "DELETE FROM items WHERE uuid=?", database: db, statement: &statement)
        if result == SQLITE_OK { result = bindString(statement, 1, item.uuid) }
        if result == SQLITE_OK {
            result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                return
            }
        }
        recordFailure(#function, #line, result)
    }

    /// The `categories` rowid of `uti`, inserting a row for a new one.
    @objc(_categoryIDForCategoryUTI:)
    func _categoryID(forCategoryUTI uti: String?) -> NSNumber? {
        guard let uti else { return nil }
        if let id = categories.object(forKey: uti as NSString) {
            return id
        }
        let rowid = _insertRow(intoTable: "categories", withProperties: ["uti": uti])
        guard rowid != 0 else { return nil }
        let id = NSNumber(value: rowid)
        categories.setObject(id, forKey: uti as NSString)
        return id
    }

    @objc(_updateCategoryStorageForItem:withCategory:)
    func _updateCategoryStorageForItem(_ item: LPItem, withCategory category: String?) {
        let id: Any = _categoryID(forCategoryUTI: category) ?? NSNull()
        _updateItem(item, withColumnValues: ["category_id": id])
    }

    /// Writes the icon sizes and image data. Items have no icons until 1.3, which the original
    /// writes as sizes 0 and no data.
    @objc(_updateImageStorageForItem:)
    func _updateImageStorageForItem(_ item: LPItem) {
        let sql = "UPDATE image_cache SET size_big=?, size_mini=?, image_data=?, image_data_mini=? WHERE item_id IN (SELECT rowid FROM items WHERE uuid=?);"
        var statement: OpaquePointer?
        var result = statement_cache.statement(with: sql, database: db, statement: &statement)
        if result == SQLITE_OK { result = sqlite3_bind_int64(statement, 1, 0) }
        if result == SQLITE_OK { result = sqlite3_bind_int64(statement, 2, 0) }
        if result == SQLITE_OK { result = sqlite3_bind_null(statement, 3) }
        if result == SQLITE_OK { result = sqlite3_bind_null(statement, 4) }
        if result == SQLITE_OK { result = bindString(statement, 5, item.uuid) }
        if result == SQLITE_OK {
            result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                return
            }
        }
        recordFailure(#function, #line, result)
    }

    private func recordFailure(_ method: String, _ line: Int, _ result: Int32) {
        NSLog("SQLite failure in %@ for %@ lineNum=%ld err=%d (%s)", method, self, line, result, sqlite3_errmsg(db))
        _commitException = LPDatabaseException(exceptionInMethod: method, lineNumber: Int64(line), database: db, ret: result)
    }
}

// MARK: - Binding

/// Binds a value by its type: nil or `NSNull` as NULL, strings as text, numbers as a double or an
/// integer by their type, data as a blob (empty data as NULL), a `CFUUID` as its string.
private func bindObject(_ statement: OpaquePointer?, _ index: Int32, _ value: Any?) -> Int32 {
    switch value {
    case nil, is NSNull:
        return sqlite3_bind_null(statement, index)
    case let string as String:
        return bindString(statement, index, string)
    case let number as NSNumber:
        switch CFNumberGetType(number) {
        case .float32Type, .float64Type, .floatType, .doubleType, .cgFloatType:
            return sqlite3_bind_double(statement, index, number.doubleValue)
        default:
            return sqlite3_bind_int64(statement, index, number.int64Value)
        }
    case let data as Data:
        guard !data.isEmpty else { return sqlite3_bind_null(statement, index) }
        return data.withUnsafeBytes {
            sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), sqliteTransient)
        }
    default:
        if let value = value as AnyObject?, CFGetTypeID(value) == CFUUIDGetTypeID() {
            let uuid = unsafeDowncast(value, to: CFUUID.self)
            return bindString(statement, index, CFUUIDCreateString(nil, uuid) as String)
        }
        return SQLITE_OK
    }
}

private func bindString(_ statement: OpaquePointer?, _ index: Int32, _ string: String?) -> Int32 {
    guard let string else { return sqlite3_bind_null(statement, index) }
    return sqlite3_bind_text(statement, index, string, -1, sqliteTransient)
}

private func columnString(_ statement: OpaquePointer?, _ index: Int32) -> String? {
    sqlite3_column_text(statement, index).map { String(cString: $0) }
}

/// A string as a quoted SQL literal's contents.
private func sqlText(_ string: String) -> String {
    string.replacingOccurrences(of: "'", with: "''")
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One shared instance per category string, as the original keeps them.
func uniqueCategoryString(_ string: String) -> String {
    categoryStrings.withLock { set in
        if let member = set.member(string) as? String {
            return member
        }
        set.add(string)
        return string
    }
}

private let categoryStrings = Mutex(NSMutableSet())

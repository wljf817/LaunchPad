import Foundation
import LaunchPadPrivate
import Testing
@testable import LaunchPad

/// The database (task 5.2, REF-LAYOUT-002).
@MainActor
struct StorageTests {
    let directory = TemporaryDirectory()

    var databasePath: String { directory.path("db") }

    /// Columns of each table as (name, declared type, not null, primary key), REF-LAYOUT-002.
    static let expectedColumns: [String: [String]] = [
        "dbinfo": ["key VARCHAR 0 0", "value VARCHAR 0 0"],
        "items": ["rowid INTEGER 0 1", "uuid VARCHAR 0 0", "flags INTEGER 0 0", "type INTEGER 0 0", "parent_id INTEGER 1 0", "ordering INTEGER 0 0"],
        "apps": ["item_id INTEGER 0 1", "title VARCHAR 0 0", "bundleid VARCHAR 0 0", "storeid VARCHAR 0 0", "category_id INTEGER 0 0", "moddate REAL 0 0", "bookmark BLOB 0 0"],
        "groups": ["item_id INTEGER 0 1", "category_id INTEGER 0 0", "title VARCHAR 0 0"],
        "downloading_apps": ["item_id INTEGER 0 1", "title VARCHAR 0 0", "bundleid VARCHAR 0 0", "storeid VARCHAR 0 0", "category_id INTEGER 0 0", "install_path VARCHAR 0 0"],
        "categories": ["rowid INTEGER 0 1", "uti VARCHAR 0 0"],
        "app_sources": ["rowid INTEGER 0 1", "uuid VARCHAR 0 0", "flags INTEGER 0 0", "bookmark BLOB 0 0", "last_fsevent_id INTEGER 0 0", "fsevent_uuid VARCHAR 0 0"],
        "image_cache": ["item_id INTEGER 0 0", "size_big INTEGER 0 0", "size_mini INTEGER 0 0", "image_data BLOB 0 0", "image_data_mini BLOB 0 0"],
    ]

    static func schema(_ path: String) -> [String] {
        queryRows(path, "SELECT type, name, tbl_name FROM sqlite_master ORDER BY rowid").map {
            "\($0["type"]! as! String) \($0["name"]! as! String) \($0["tbl_name"]! as! String)"
        }
    }

    static func columns(_ path: String, _ table: String) -> [String] {
        queryRows(path, "PRAGMA table_info(\(table))").map {
            "\($0["name"]! as! String) \($0["type"]! as! String) \($0["notnull"]! as! Int64) \($0["pk"]! as! Int64)"
        }
    }

    @Test("首次启动建库")
    func newDatabase() async throws {
        let (storage, root, versionsRoot, sources) = await openStorage(at: databasePath)
        let theRoot = try #require(root)
        let theVersionsRoot = try #require(versionsRoot)
        #expect(theRoot.uuid == "ROOTPAGE")
        #expect(theVersionsRoot.uuid == "ROOTPAGE_VERS")
        #expect(theRoot.storageChildren.map { ($0 as! LPItem).uuid } == ["HOLDINGPAGE"])
        #expect(theVersionsRoot.storageChildren.map { ($0 as! LPItem).uuid } == ["HOLDINGPAGE_VERS"])
        #expect(theRoot.children.count == 0)
        #expect(sources?.isEmpty ?? true)
        // A new database keeps no dbinfo dictionary until it is opened again.
        #expect(storage.dbInfo == nil)
        #expect(!storage.initalSetupComplete)

        #expect(Self.schema(databasePath) == [
            "table dbinfo dbinfo", "table items items", "table apps apps", "table groups groups",
            "table downloading_apps downloading_apps", "table categories categories", "table app_sources app_sources",
            "table image_cache image_cache",
            "trigger update_items_order items", "trigger update_items_order_backwards items", "trigger update_item_parent items",
            "trigger insert_item items", "trigger app_inserted items", "trigger app_deleted items", "trigger item_deleted items",
            "index items_uuid_index items", "index items_ordering_index items", "index items_type items",
            "index image_cache_index image_cache",
        ])
        for (table, columns) in Self.expectedColumns {
            #expect(Self.columns(databasePath, table) == columns, "\(table)")
        }
        #expect(queryRows(databasePath, "PRAGMA journal_mode").first?["journal_mode"] as? String == "wal")

        let build = (_CFCopySystemVersionDictionary()?.takeRetainedValue() as NSDictionary?)?[_kCFSystemVersionBuildVersionKey as String] as? String
        let dbinfo = queryRows(databasePath, "SELECT key, value FROM dbinfo ORDER BY rowid").map { "\($0["key"]! as! String)=\($0["value"]! as! String)" }
        #expect(dbinfo == [
            "ignore_items_update_triggers=0", "setup_incomplete=1", "launchpad_root=1", "launchpad_version_root=5",
            "compatibleVersion=6", "version=13", "build=\(build ?? "NULL")", "localization=\(LPStorage.currentLocalization ?? "")",
            "region_code=\(LPStorage.currentRegionCode ?? "")", "curateListVersionLP=1", "excludeListVersionLP=3",
            "includeAsGameListVersionLP=1",
        ])
        let items = queryRows(databasePath, "SELECT rowid, uuid, type, parent_id, ordering FROM items ORDER BY rowid").map {
            "\($0["rowid"]! as! Int64) \($0["uuid"]! as! String) \($0["type"]! as! Int64) \($0["parent_id"]! as! Int64) \($0["ordering"]! as! Int64)"
        }
        #expect(items == ["1 ROOTPAGE 1 0 0", "2 HOLDINGPAGE 3 1 0", "4 HOLDINGPAGE_DB 3 3 0", "5 ROOTPAGE_VERS 1 0 0", "6 HOLDINGPAGE_VERS 3 5 0"])
        #expect(queryRows(databasePath, "SELECT item_id FROM groups ORDER BY item_id").map { $0["item_id"]! as! Int64 } == [1, 2, 4, 5, 6])

        if let evidence = originalEvidence {
            let original = evidence.appendingPathComponent("db-snapshot/db-checkpointed").path
            let copy = directory.path("original")
            try FileManager.default.copyItem(atPath: original, toPath: copy)
            #expect(Self.schema(copy) == Self.schema(databasePath))
            for table in Self.expectedColumns.keys {
                #expect(Self.columns(copy, table) == Self.columns(databasePath, table), "\(table)")
            }
        }
    }

    @Test("再次启动")
    func savedTreeReadsBack() async throws {
        let apps = directory.path("Applications")
        try makeAppBundle(at: apps + "/One.app", bundleID: "com.example.one", info: ["LSApplicationCategoryType": "public.app-category.games"])
        try makeAppBundle(at: apps + "/Two.app", bundleID: "com.example.two")
        try makeAppBundle(at: apps + "/Three.app", bundleID: "com.example.three")

        let (storage, root, _, _) = await openStorage(at: databasePath)
        let theRoot = try #require(root)
        let one = try #require(LPApp(url: URL(fileURLWithPath: apps + "/One.app"), forScan: 1))
        let two = try #require(LPApp(url: URL(fileURLWithPath: apps + "/Two.app"), forScan: 1))
        let three = try #require(LPApp(url: URL(fileURLWithPath: apps + "/Three.app"), forScan: 1))

        let page = LPPage(items: nil)
        theRoot.children.add(page)
        page.children.add(one)
        let folder = LPGroup(groupWithTitle: "Folder", andChildren: nil)
        page.children.insert(folder, at: 0)
        let folderPage = LPPage(items: nil)
        folder.children.add(folderPage)
        folderPage.children.add(two)
        theRoot.addItemToPurgatory(three)
        folder.title = "Renamed"
        folder.autoGenerated = true
        storage.markInitialSetupComplete()
        await waitForDatabase(storage)

        let apps2 = queryRows(databasePath, "SELECT apps.title, apps.bundleid, categories.uti, image_cache.size_big FROM apps JOIN items ON apps.rowid = items.rowid JOIN image_cache ON image_cache.item_id = apps.rowid LEFT JOIN categories ON apps.category_id = categories.rowid ORDER BY items.rowid")
        #expect(apps2.map { $0["title"]! as? String } == ["One", "Two", "Three"])
        #expect(apps2.map { $0["uti"]! as? String } == ["public.app-category.games", nil, nil])
        #expect(apps2.map { $0["size_big"]! as? Int64 } == [0, 0, 0])
        #expect(queryRows(databasePath, "SELECT value FROM dbinfo WHERE key = 'setup_incomplete'").isEmpty)

        let (reopened, readRoot, _, _) = await openStorage(at: databasePath)
        let rereadRoot = try #require(readRoot)
        #expect(treeDescription(rereadRoot) == treeDescription(theRoot))
        #expect(reopened.initalSetupComplete)
        #expect(reopened.dbInfo?["setup_incomplete"] == nil)
        let readFolder = try #require((rereadRoot.children[0] as? LPPage)?.children[0] as? LPGroup)
        #expect(readFolder.title == "Renamed")
        #expect(readFolder.autoGenerated)
        let readOne = try #require((rereadRoot.children[0] as? LPPage)?.children[1] as? LPApp)
        #expect(readOne.bundleIdentifier == "com.example.one")
        #expect(readOne.categoryUTI == "public.app-category.games")
        #expect(readOne.lastURL?.standardizedFileURL.path == one.lastURL?.standardizedFileURL.path)
        #expect(readOne.modificationTime == one.modificationTime)
        #expect(readOne.bookmarkData == one.bookmarkData)
        #expect(readOne.storage === reopened)
    }

    @Test func removingAndReorderingKeepsOrderings() async throws {
        let (storage, root, _, _) = await openStorage(at: databasePath)
        let theRoot = try #require(root)
        let page = LPPage(items: nil)
        theRoot.children.add(page)
        let folders = (0..<4).map { LPGroup(groupWithTitle: "F\($0)", andChildren: nil) }
        page.children.addObjects(from: folders)
        page.children.insert(folders[3], at: 1)
        page.children.remove(folders[0])
        let other = LPPage(items: nil)
        theRoot.children.add(other)
        other.children.add(folders[1])
        await waitForDatabase(storage)

        func titles(_ pageUUID: String?) -> [String] {
            queryRows(databasePath, "SELECT groups.title FROM items JOIN groups ON groups.item_id = items.rowid WHERE parent_id = (SELECT rowid FROM items WHERE uuid = '\(pageUUID!)') ORDER BY ordering").map { $0["title"]! as! String }
        }
        #expect(titles(page.uuid) == ["F3", "F2"])
        #expect(titles(other.uuid) == ["F1"])
        let orderings = queryRows(databasePath, "SELECT ordering FROM items WHERE parent_id = (SELECT rowid FROM items WHERE uuid = '\(page.uuid!)') ORDER BY ordering").map { $0["ordering"]! as! Int64 }
        #expect(orderings == [0, 1])
    }

    /// Runs the same inserts, moves and deletes on a copy of the original's database and on this
    /// project's database holding the same rows, then compares every table.
    @Test("触发器的效果", .enabled(if: originalEvidence != nil))
    func triggerEffects() async throws {
        let evidence = try #require(originalEvidence)
        let original = directory.path("original")
        try FileManager.default.copyItem(atPath: evidence.appendingPathComponent("db-snapshot/db-checkpointed").path, toPath: original)
        let (storage, _, _, _) = await openStorage(at: databasePath)
        await waitForDatabase(storage)
        let copyRows = """
            ATTACH DATABASE '\(original)' AS original;
            UPDATE dbinfo SET value = 1 WHERE key = 'ignore_items_update_triggers';
            DELETE FROM items; DELETE FROM apps; DELETE FROM groups; DELETE FROM image_cache; DELETE FROM categories;
            UPDATE dbinfo SET value = 1 WHERE key = 'ignore_items_update_triggers';
            INSERT INTO items SELECT * FROM original.items;
            DELETE FROM image_cache;
            INSERT INTO apps SELECT * FROM original.apps;
            INSERT INTO groups SELECT * FROM original.groups;
            INSERT INTO image_cache SELECT * FROM original.image_cache;
            INSERT INTO categories SELECT * FROM original.categories;
            DELETE FROM dbinfo;
            INSERT INTO dbinfo SELECT * FROM original.dbinfo;
            DETACH DATABASE original;
            """
        #expect(execute(databasePath, copyRows) == 0)

        let page = queryRows(original, "SELECT parent_id FROM items WHERE type = 4 GROUP BY parent_id ORDER BY COUNT(*) DESC LIMIT 2").map { $0["parent_id"]! as! Int64 }
        let firstApp = queryRows(original, "SELECT uuid FROM items WHERE parent_id = \(page[0]) ORDER BY ordering LIMIT 1")[0]["uuid"]! as! String
        let folder = queryRows(original, "SELECT uuid FROM items WHERE type = 2 LIMIT 1")[0]["uuid"]! as! String
        let operations = """
            INSERT INTO items (uuid, flags, type, parent_id) VALUES ('TEST-APP', 0, 4, \(page[0]));
            INSERT INTO items (uuid, flags, type, parent_id) VALUES ('TEST-PAGE', 0, 3, \(page[1]));
            UPDATE items SET ordering = 2 WHERE uuid = 'TEST-APP';
            UPDATE items SET ordering = 5 WHERE uuid = '\(firstApp)';
            UPDATE items SET ordering = NULL, parent_id = \(page[1]) WHERE uuid = 'TEST-APP';
            UPDATE items SET ordering = 0 WHERE uuid = 'TEST-APP';
            DELETE FROM items WHERE uuid = '\(firstApp)';
            DELETE FROM items WHERE uuid = '\(folder)';
            DELETE FROM items WHERE uuid = 'TEST-PAGE';
            """
        #expect(execute(original, operations) == 0)
        #expect(execute(databasePath, operations) == 0)
        for table in ["items", "apps", "groups", "image_cache", "categories", "dbinfo"] {
            let sql = "SELECT * FROM \(table) ORDER BY rowid"
            #expect(rowLines(databasePath, sql) == rowLines(original, sql), "\(table)")
        }
    }

    /// Reads a copy of the reference VM's database and compares the tree with the one the
    /// original Dock read from the same database (research, `runtime-tree-20261018.json`).
    @Test("读原版的数据库", .enabled(if: originalEvidence != nil))
    func readsTheOriginalDatabase() async throws {
        let evidence = try #require(originalEvidence)
        try FileManager.default.copyItem(atPath: evidence.appendingPathComponent("db-snapshot/db-checkpointed").path, toPath: databasePath)
        let (_, root, versionsRoot, _) = await openStorage(at: databasePath)
        let data = try Data(contentsOf: evidence.appendingPathComponent("runtime-tree-20261018.json"))
        let runtime = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        func lines(_ node: [String: Any], depth: Int = 0) -> [String] {
            var result = [String(repeating: "  ", count: depth) + "\(node["class"]!) \(node["uuid"]!)"]
            for child in node["children"] as? [[String: Any]] ?? [] {
                result += lines(child, depth: depth + 1)
            }
            return result
        }
        func lines(_ item: LPItem, depth: Int = 0) -> [String] {
            var result = [String(repeating: "  ", count: depth) + "\(NSStringFromClass(type(of: item))) \(item.uuid!)"]
            for case let child as LPItem in (item as? LPGroup)?.storageChildren ?? [] {
                result += lines(child, depth: depth + 1)
            }
            return result
        }
        #expect(lines(try #require(root)) == lines(runtime[0]))
        #expect(lines(try #require(versionsRoot)) == lines(runtime[1]))
    }
}

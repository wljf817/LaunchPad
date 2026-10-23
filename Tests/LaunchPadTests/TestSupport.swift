import Foundation
import SQLite3
import Testing
@testable import LaunchPad

/// A directory under `~/Library/Caches`, removed when the value goes away. Not under the temporary
/// directory: the scan, like the original's, computes paths relative to the scanned path, and the
/// directory enumerator reports paths under `/var` with their `/private` prefix.
final class TemporaryDirectory: @unchecked Sendable {
    let url: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        url = caches.appendingPathComponent("LaunchPadTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func path(_ component: String) -> String {
        url.appendingPathComponent(component).path
    }
}

/// Writes a minimal application bundle: an Info.plist and a copy of `/usr/bin/true` as the
/// executable, the way the reference VM's test bundles were made (REF-LAYOUT-008).
@discardableResult
func makeAppBundle(at path: String, bundleID: String?, version: String = "1.0", info: [String: Any] = [:]) throws -> URL {
    let url = URL(fileURLWithPath: path, isDirectory: true)
    let contents = url.appendingPathComponent("Contents")
    let macOS = contents.appendingPathComponent("MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let name = url.deletingPathExtension().lastPathComponent
    var plist: [String: Any] = [
        "CFBundleName": name,
        "CFBundleExecutable": name,
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": version,
        "CFBundleShortVersionString": version,
        "LSMinimumSystemVersion": "11.0",
    ]
    if let bundleID {
        plist["CFBundleIdentifier"] = bundleID
    }
    plist.merge(info) { _, new in new }
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent(name).path)
    return url
}

/// An app item that was never scanned, for tests of the tree alone.
func makeTestApp(_ title: String, bundleID: String? = nil) -> LPApp {
    let app = LPApp(forCopy: ())
    app.uuid = newUUIDString()
    app._title = title
    app.bundleID = bundleID
    return app
}

/// Opens a storage and waits for its callback.
func openStorage(at path: String, readOnly: Bool = false) async -> (storage: LPStorage, root: LPRoot?, versionsRoot: LPRoot?, sources: [LPAppSource]?) {
    nonisolated(unsafe) var storage: LPStorage!
    let values: (LPRoot?, LPRoot?, [LPAppSource]?) = await withCheckedContinuation { continuation in
        storage = LPStorage(path: path, readOnly: readOnly) { root, versionsRoot, sources in
            let values = (root, versionsRoot, sources)
            continuation.resume(returning: values)
        }
    }
    return (storage, values.0, values.1, values.2)
}

/// Returns once the main queue has run what was queued before.
@MainActor
func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

/// Returns once the storage has run the transactions committed so far.
func waitForDatabase(_ storage: LPStorage) async {
    await withCheckedContinuation { continuation in
        storage.db_queue.async { continuation.resume() }
    }
}

/// Rows of a query, each as column name → value (`Int64`, `Double`, `String`, `Data` or nil).
func queryRows(_ path: String, _ sql: String) -> [[String: Any?]] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(statement) }
    var rows: [[String: Any?]] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        var row: [String: Any?] = [:]
        for index in 0..<sqlite3_column_count(statement) {
            let name = String(cString: sqlite3_column_name(statement, index))
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER: row[name] = sqlite3_column_int64(statement, index)
            case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, index)
            case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, index))
            case SQLITE_BLOB:
                row[name] = Data(bytes: sqlite3_column_blob(statement, index), count: Int(sqlite3_column_bytes(statement, index)))
            default: row[name] = .some(nil)
            }
        }
        rows.append(row)
    }
    return rows
}

/// Rows of a query as lines of `column=value`, columns sorted by name.
func rowLines(_ path: String, _ sql: String) -> [String] {
    queryRows(path, sql).map { row in
        row.keys.sorted().map { "\($0)=\(row[$0]!.map { String(describing: $0) } ?? "NULL")" }.joined(separator: " ")
    }
}

/// Runs statements on a database file directly.
func execute(_ path: String, _ sql: String) -> Int32 {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return SQLITE_CANTOPEN }
    defer { sqlite3_close(db) }
    return sqlite3_exec(db, sql, nil, nil, nil)
}

/// A tree as nested lines of class name and uuid, for comparing two trees.
func treeDescription(_ item: LPItem, depth: Int = 0) -> [String] {
    var lines = [String(repeating: "  ", count: depth) + "\(type(of: item)) \(item.uuid ?? "nil") \(item.title ?? "")"]
    if let group = item as? LPGroup {
        for case let child as LPItem in group.storageChildren {
            lines += treeDescription(child, depth: depth + 1)
        }
    }
    return lines
}

/// A bundle with this project's `LaunchPadLayout.plist` and only the `zh_CN` strings, used by every
/// test as the app bundle (`launchPadBundle`). With a single localization, lookups in it give the
/// `zh_CN` titles whatever the test process's languages are (REF-LAYOUT-009).
let testResources: Bundle = {
    let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LaunchPad/Resources")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchPadTests-resources-\(getpid())")
    try? FileManager.default.removeItem(at: directory)
    try! FileManager.default.createDirectory(at: directory.appendingPathComponent("zh_CN.lproj"), withIntermediateDirectories: true)
    try! FileManager.default.copyItem(at: resources.appendingPathComponent("LaunchPadLayout.plist"), to: directory.appendingPathComponent("LaunchPadLayout.plist"))
    try! FileManager.default.copyItem(at: resources.appendingPathComponent("zh_CN.lproj/Localizable.strings"),
                                      to: directory.appendingPathComponent("zh_CN.lproj/Localizable.strings"))
    return Bundle(path: directory.path)!
}()

/// The research evidence directory (`research/…/notes/lp-model`) given by `LAUNCHPAD_ORIGINAL_DB`,
/// for tests against the original's database.
let originalEvidence: URL? = ProcessInfo.processInfo.environment["LAUNCHPAD_ORIGINAL_DB"].map { URL(fileURLWithPath: $0) }

/// Waits until a controller has handled the first scan with its roots, and the database has written
/// what that queued.
@MainActor
func waitUntilStarted(_ springboard: Springboard) async throws {
    let deadline = Date().addingTimeInterval(120)
    while !springboard.scanningComplete || springboard.rootPage == nil {
        try #require(Date() < deadline, "the first scan was not handled")
        try await Task.sleep(for: .milliseconds(10))
    }
    // Let the main queue run what the startup queued (dbinfo writes of completion blocks).
    try await Task.sleep(for: .milliseconds(50))
    if let storage = springboard.appManager?.storage {
        await waitForDatabase(storage)
    }
    await waitForIconGeneration(springboard.appManager?.storage)
}

/// Returns once the icon generations queued so far have run: each goes through the information
/// queue and the main queue a few times, then writes to the database (REF-GRID-012).
@MainActor
func waitForIconGeneration(_ storage: LPStorage?) async {
    for _ in 0..<5 {
        await withCheckedContinuation { continuation in
            LPRunnable.application_info_queue.async { continuation.resume() }
        }
        await drainMainQueue()
        if let storage {
            await waitForDatabase(storage)
        }
    }
}

/// The grid's item tree mirrors the layout root's pages, apps and folders, in order, and every page
/// has its page (research paper §6.1, REF-GRID-003).
@MainActor
func expectItemTree(_ springboard: Springboard, sourceLocation: SourceLocation = #_sourceLocation) {
    guard let root = springboard.rootPage else {
        Issue.record("no root", sourceLocation: sourceLocation)
        return
    }
    let item = springboard.springboard.item
    let pageItems = (item.items as? [ECSBPageItem]) ?? []
    let pages = root.children as! [LPPage]
    #expect(pageItems.count == pages.count, sourceLocation: sourceLocation)
    for (pageItem, page) in zip(pageItems, pages) {
        #expect(pageItem.clientItem === page, sourceLocation: sourceLocation)
        #expect(pageItem.parent === item, sourceLocation: sourceLocation)
        #expect(pageItem.page != nil, sourceLocation: sourceLocation)
        expectItems(of: pageItem, mirroring: page, sourceLocation: sourceLocation)
    }
}

@MainActor
func expectItems(of container: ECSBContainerItem, mirroring group: LPGroup, sourceLocation: SourceLocation) {
    let items = (container.items as? [ECSBItem]) ?? []
    let children = group.children as! [LPItem]
    #expect(items.count == children.count, sourceLocation: sourceLocation)
    for (item, child) in zip(items, children) {
        #expect(item.clientItem === child, sourceLocation: sourceLocation)
        #expect(item.parent === container, sourceLocation: sourceLocation)
        if let folder = child as? LPGroup {
            guard let groupItem = item as? ECSBGroupItem else {
                Issue.record("\(child) is not a folder item", sourceLocation: sourceLocation)
                continue
            }
            let folderPageItems = (groupItem.items as? [ECSBPageItem]) ?? []
            let folderPages = folder.children as! [LPPage]
            #expect(folderPageItems.count == folderPages.count, sourceLocation: sourceLocation)
            for (pageItem, page) in zip(folderPageItems, folderPages) {
                #expect(pageItem.clientItem === page, sourceLocation: sourceLocation)
                #expect(pageItem.parent === groupItem, sourceLocation: sourceLocation)
                expectItems(of: pageItem, mirroring: page, sourceLocation: sourceLocation)
            }
        } else {
            #expect(type(of: item) == ECSBItem.self, sourceLocation: sourceLocation)
        }
    }
}

import Foundation
import LaunchPadPrivate
import SQLite3
import UniformTypeIdentifiers

/// Something Launchpad can open: the base of `LPApp`.
@objc(LPRunnable)
class LPRunnable: LPItem, LPLayoutItem, @unchecked Sendable {
    /// Read by `LPStorage` through KVC under this name, so the stored property keeps the ivar name.
    @objc var _bookmarkData: Data?
    var _lastURL: URL?
    var hasMigratedLastURL = false
    var _lastKnownVersion = kLSVersionNumberNull
    var _categoryUTI: String?
    var _storeID: String?
    var bundleID: String?
    var _modificationTime: Double = 0
    var _lastScan: UInt32 = 0
    @objc var isRestricted = false

    @objc(initWithURL:forScan:)
    init?(url: URL, forScan scan: UInt32) {
        super.init(title: nil)
        _lastScan = scan
    }

    /// Decodes `title`, `storeid`, `moddate`, `bookmark`, the category's `uti` and the two icon
    /// column pairs after the `LPItem` columns.
    @objc(initWithSQLStatement:withColumn:)
    required init?(sqlStatement statement: OpaquePointer, withColumn column: UnsafeMutablePointer<Int32>) {
        super.init(sqlStatement: statement, withColumn: column)
        if let text = sqlite3_column_text(statement, column.pointee) {
            _title = String(cString: text)
        }
        column.pointee += 1
        if let text = sqlite3_column_text(statement, column.pointee) {
            _storeID = String(cString: text)
        }
        column.pointee += 1
        _modificationTime = sqlite3_column_double(statement, column.pointee)
        column.pointee += 1
        let blob = sqlite3_column_blob(statement, column.pointee)
        let length = sqlite3_column_bytes(statement, column.pointee)
        column.pointee += 1
        if length != 0, let blob {
            _bookmarkData = Data(bytes: blob, count: Int(length))
            if let bookmark = _bookmarkData,
               let path = NSURL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark)?[.pathKey] as? String {
                _lastURL = URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        if let text = sqlite3_column_text(statement, column.pointee) {
            _categoryUTI = uniqueCategoryString(String(cString: text))
        }
        column.pointee += 1
        // The large and the mini icon: a size and the image data each. Icons are loaded in 1.3.
        column.pointee += 4
    }

    required init(forCopy: ()) {
        super.init(forCopy: ())
    }

    @objc(snapshotForStorage:deepCopy:)
    override func snapshotForStorage(_ forStorage: Bool, deepCopy: Bool) -> LPItem {
        let copy = super.snapshotForStorage(forStorage, deepCopy: deepCopy) as! LPRunnable
        copy._bookmarkData = _bookmarkData
        copy._categoryUTI = _categoryUTI
        copy.bundleID = bundleID
        copy._storeID = _storeID
        copy._lastURL = _lastURL
        copy.hasMigratedLastURL = hasMigratedLastURL
        copy._lastKnownVersion = _lastKnownVersion
        copy._modificationTime = _modificationTime
        copy._lastScan = _lastScan
        return copy
    }

    @objc var bookmarkData: Data? { _bookmarkData }
    @objc var lastURL: URL? { _lastURL }
    @objc var lastKnownVersion: LSVersionNumber { _lastKnownVersion }
    @objc var categoryUTI: String? { _categoryUTI }
    @objc var storeID: String? { _storeID }
    @objc var bundleIdentifier: String? { bundleID }
    @objc var modificationTime: Double { _modificationTime }
    @objc var lastScan: UInt32 { _lastScan }

    @objc var resolvesBookmarks: Bool { false }

    // Flag bits of `items.flags` (REF-LAYOUT-003).

    @objc var isStoreApp: Bool { flags & 0x1 != 0 }
    @objc var isSymlink: Bool { flags & 0x10 != 0 }
    @objc var isAlias: Bool { flags & 0x20 != 0 }
    @objc func uiElement() -> Bool { flags & 0x8 != 0 }

    @objc var notFound: Bool {
        get { flags & 0x2 != 0 }
        set {
            guard newValue != notFound else { return }
            flags = flags & ~0x2 | (newValue ? 0x2 : 0)
        }
    }

    @objc var addedByUser: Bool {
        get { flags & 0x100 != 0 }
        set {
            guard newValue != addedByUser else { return }
            flags = flags & ~0x100 | (newValue ? 0x100 : 0)
        }
    }

    @objc var isBeta: Bool {
        get { flags & 0x800 != 0 }
        set {
            guard newValue != isBeta else { return }
            flags = flags & ~0x800 | (newValue ? 0x800 : 0)
        }
    }

    private static let gamesType = UTType("public.app-category.games")
    private static let boardGamesType = UTType("public.app-category.board-games")

    /// The category conforms to games or board games.
    @objc func isGame() -> Bool {
        guard let categoryUTI = _categoryUTI, let type = UTType(categoryUTI) else { return false }
        if let games = Self.gamesType, type.conforms(to: games) {
            return true
        }
        guard let boardGames = Self.boardGamesType else { return false }
        return type.conforms(to: boardGames)
    }

    /// The name the exclude list's rules match: the bundle's file name without its extension, or
    /// the title when there is no URL.
    @objc var excludeListName: String? {
        guard let path = _lastURL?.path else { return title }
        return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    // MARK: Versions

    @objc(versionFromInfoDictionary:)
    func versionFromInfoDictionary(_ info: NSDictionary) -> LSVersionNumber {
        let value = info["CFBundleVersion"]
        let string = value is NSString ? value as? String : (value as AnyObject?)?.description
        guard let string else { return kLSVersionNumberNull }
        return _LSGetVersionFromString(string as CFString)
    }

    @objc(versionFromAppURL:)
    func versionFromAppURL(_ url: URL?) -> LSVersionNumber {
        guard let url, let info = CFBundleCopyInfoDictionaryForURL(url as CFURL) else {
            return kLSVersionNumberNull
        }
        return versionFromInfoDictionary(info as NSDictionary)
    }

    // MARK: Bookmarks

    /// The serial queue that resolves bookmarks, "LPApp information gathering".
    @objc class var application_info_queue: DispatchQueue { informationQueue }
    private static let informationQueue = DispatchQueue(label: "LPApp information gathering")

    @objc(resolveURLFromBookMark:url:)
    func resolveURLFromBookMark(_ updateBookmark: Bool, url block: (@convention(block) (URL?) -> Void)?) {
        resolveURLFromBookMark(updateBookmark, updateVersion: false) { url, _ in
            block?(url)
        }
    }

    /// Finds where the runnable is now, on the information queue: its bookmark when it resolves
    /// bookmarks, otherwise its last URL if a file is still there. Back on the main thread it records
    /// what it found (URL and refreshed bookmark when the bookmark was stale, version, `notFound`)
    /// and calls `block`.
    @objc(resolveURLFromBookMark:updateVersion:url:)
    func resolveURLFromBookMark(_ updateBookmark: Bool, updateVersion: Bool,
                                url block: @escaping @convention(block) (URL?, LSVersionNumber) -> Void) {
        let start = UncheckedBox({ [self] in
            let request = BookmarkRequest(
                runnable: self, lastURL: _lastURL, bookmark: _bookmarkData, block: block,
                resolvesBookmarks: resolvesBookmarks, hasMigratedLastURL: hasMigratedLastURL,
                updateBookmark: updateBookmark, updateVersion: updateVersion, isSymlink: isSymlink)
            LPRunnable.application_info_queue.async { request.resolve() }
        })
        if Thread.isMainThread {
            start.value()
        } else {
            DispatchQueue.main.async { start.value() }
        }
    }

    /// The values the bookmark resolution captures on the main thread.
    private struct BookmarkRequest: @unchecked Sendable {
        let runnable: LPRunnable
        let lastURL: URL?
        let bookmark: Data?
        let block: @convention(block) (URL?, LSVersionNumber) -> Void
        let resolvesBookmarks: Bool
        let hasMigratedLastURL: Bool
        let updateBookmark: Bool
        let updateVersion: Bool
        let isSymlink: Bool

        /// Runs on the information queue.
        func resolve() {
            var stale = false
            let resolved: URL?
            if resolvesBookmarks {
                if hasMigratedLastURL, let lastURL, FileManager.default.fileExists(atPath: lastURL.path) {
                    resolved = lastURL
                    stale = true
                } else {
                    resolved = bookmark.flatMap { bookmark in
                        var isStale: ObjCBool = false
                        let url = try? NSURL(resolvingBookmarkData: bookmark, options: Self.resolutionOptions,
                                             relativeTo: nil, bookmarkDataIsStale: &isStale) as URL
                        stale = isStale.boolValue
                        return url
                    }
                }
            } else {
                if let lastURL, FileManager.default.fileExists(atPath: lastURL.path) {
                    resolved = lastURL
                } else {
                    resolved = nil
                }
            }

            var newBookmark: Data?
            var version = kLSVersionNumberNull
            var notFound = true
            if let resolved {
                if stale, updateBookmark {
                    newBookmark = try? resolved.bookmarkData(options: Self.creationOptions,
                                                            includingResourceValuesForKeys: nil, relativeTo: nil)
                    if let created = newBookmark, hasMigratedLastURL {
                        var isStale: ObjCBool = false
                        let check = try? NSURL(resolvingBookmarkData: created, options: Self.resolutionOptions,
                                               relativeTo: nil, bookmarkDataIsStale: &isStale) as URL
                        if check != lastURL {
                            NSLog("resolveURLFromBookMark: %@ migrated URL bookmark didn't roundtrip", runnable)
                            newBookmark = nil
                        }
                    }
                }
                if updateVersion {
                    version = runnable.versionFromAppURL(resolved)
                }
                if isSymlink {
                    var destination = (try? FileManager.default.destinationOfSymbolicLink(atPath: resolved.path)) ?? ""
                    if !(destination as NSString).isAbsolutePath {
                        destination = ((resolved.path as NSString).deletingLastPathComponent as NSString)
                            .appendingPathComponent(destination)
                    }
                    notFound = !FileManager.default.fileExists(atPath: destination)
                } else {
                    notFound = false
                }
            }

            let result = BookmarkResult(request: self, resolved: resolved, newBookmark: newBookmark,
                                        stale: stale, notFound: notFound, version: version)
            DispatchQueue.main.async { result.apply() }
        }

        /// Without UI, without mounting, and 0x10000, as the original passes them.
        static let resolutionOptions = NSURL.BookmarkResolutionOptions(rawValue: 0x10300)
        /// The options `_collectApplicationInfoForURL:` creates bookmarks with.
        static let creationOptions = URL.BookmarkCreationOptions(rawValue: 0x2000_0200)
    }

    private struct BookmarkResult: @unchecked Sendable {
        let request: BookmarkRequest
        let resolved: URL?
        let newBookmark: Data?
        let stale: Bool
        let notFound: Bool
        let version: LSVersionNumber

        /// Runs on the main thread.
        func apply() {
            let runnable = request.runnable
            if stale, !notFound {
                runnable._lastURL = resolved
                if request.updateBookmark, let newBookmark {
                    runnable._bookmarkData = newBookmark
                    runnable.hasMigratedLastURL = false
                    runnable.updateBookmarkStorage()
                }
            }
            if request.updateVersion, !notFound {
                runnable._lastKnownVersion = version
            }
            if notFound != runnable.notFound {
                runnable.notFound = notFound
            }
            request.block(resolved, runnable._lastKnownVersion)
        }
    }

    // MARK: Updating from a newer scan

    /// Takes over what a new scan found for the same app, keeping the database in step.
    @objc(updateInfoFromRunnable:)
    func updateInfoFromRunnable(_ runnable: LPRunnable) {
        let newURL = runnable.lastURL
        let newBundleID = runnable.bundleIdentifier
        guard type(of: self) == type(of: runnable) else { return }
        _lastScan = runnable.lastScan
        if !isEqualToString(title, runnable.title) {
            title = runnable.title
        }
        if _categoryUTI != nil || runnable._categoryUTI != nil, !isEqualToString(_categoryUTI, runnable._categoryUTI) {
            _categoryUTI = runnable._categoryUTI
            updateCategoryStorage()
        }
        // The original replaces the bundle ID only when the two are already equal.
        if isEqualToString(bundleIdentifier, runnable.bundleIdentifier) {
            bundleID = newBundleID
            updateBundleIdentifier()
        }
        if let bookmark = runnable._bookmarkData, _bookmarkData != bookmark {
            _bookmarkData = bookmark
            _lastURL = newURL
            hasMigratedLastURL = runnable.hasMigratedLastURL
            updateBookmarkStorage()
        }
        if modificationTime != runnable.modificationTime {
            willChangeValue(forKey: "modificationTime")
            _modificationTime = runnable.modificationTime
            didChangeValue(forKey: "modificationTime")
            updateModeTimeStorage()
        }
        if isRestricted != runnable.isRestricted {
            willChangeValue(forKey: "isRestricted")
            isRestricted = runnable.isRestricted
            didChangeValue(forKey: "isRestricted")
        }
        if isBeta != runnable.isBeta {
            willChangeValue(forKey: "isBeta")
            isBeta = runnable.isBeta
            didChangeValue(forKey: "isBeta")
        }
        _lastKnownVersion = runnable.lastKnownVersion
        // Here the original reloads the icons, which arrive in 1.3.
        let newFlags = runnable.flags
        flags = newFlags & ~0x3fff | newFlags & 0xff | (flags >> 8 & 0x3f) << 8
    }
}

// MARK: - LPStorage

extension LPRunnable {
    @objc(insertIntoStorage:parent:withOrder:)
    override func insertIntoStorage(_ storage: AnyObject, parent parentUUID: String, withOrder order: Int) {
        super.insertIntoStorage(storage, parent: parentUUID, withOrder: order)
        let storage = storage as! LPStorage
        storage._updateImageStorageForItem(self)
        storage._updateCategoryStorageForItem(self, withCategory: categoryUTI)
    }

    @objc func updateBundleIdentifier() {
        updateStorage(properties: ["bundleIdentifier"])
    }

    @objc func updateBookmarkStorage() {
        updateStorage(properties: ["_bookmarkData"])
    }

    @objc func updateModeTimeStorage() {
        updateStorage(properties: ["modificationTime"])
    }

    @objc func updateCategoryStorage() {
        let snapshot = snapshotForStorage(true, deepCopy: false) as! LPRunnable
        weak let storage = storage
        storage?.addBlockToDatabaseQueue {
            storage?._updateCategoryStorageForItem(snapshot, withCategory: snapshot.categoryUTI)
        }
    }

    /// The shape all of these share: a snapshot, then a block that updates the named properties.
    private func updateStorage(properties: [String]) {
        let snapshot = snapshotForStorage(true, deepCopy: false)
        weak let storage = storage
        storage?.addBlockToDatabaseQueue {
            storage?._updateItem(snapshot, withItemProperties: properties)
        }
    }
}

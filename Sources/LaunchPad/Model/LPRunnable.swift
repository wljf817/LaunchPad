import Foundation
import LaunchPadPrivate
import SQLite3
import Synchronization
import UniformTypeIdentifiers
import os

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
    /// The sizes of the last icon request, in pixels (REF-GRID-012).
    var largeIconSize: UInt = 0
    var miniIconSize: UInt = 0
    /// Counts icon requests; a generation whose count is stale before it starts is dropped.
    let loadingCounter = Atomic<Int32>(0)
    var loadingMini = false
    var reloadingFromDisk = false
    var loadingLarge = false

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
        // The large and the mini icon: a size and the image data each, into the caches (REF-GRID-012).
        readImageColumns(statement, column) { size, image in
            self.largeIconSize = size
            self.icon = image
        }
        readImageColumns(statement, column) { size, image in
            self.miniIconSize = size
            self.miniIcon = image
        }
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
        if forStorage, let uuid = uuid as NSString? {
            copy._icon = iconForStorage ?? Self.iconCache.object(forKey: uuid)
            copy._miniIcon = miniIconForStorage ?? Self.miniIconCache.object(forKey: uuid)
        }
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
        _retrieveImageOfLargeSize(largeIconSize, andMiniSize: miniIconSize, force: true)
        let newFlags = runnable.flags
        flags = newFlags & ~0x3fff | newFlags & 0xff | (flags >> 8 & 0x3f) << 8
    }
}

// MARK: - Icons

extension LPRunnable {
    /// The process-wide icon caches, keyed by the item's uuid, without a cost limit (REF-GRID-012). The
    /// original creates them in `+initialize`; the delegate only logs evictions and is set only when
    /// debug logging is on.
    nonisolated(unsafe) static let iconCache = makeIconCache(name: "LPAppIconCache")
    nonisolated(unsafe) static let miniIconCache = makeIconCache(name: "LPAppMiniIconCache")
    private static let cacheDelegate = LPAppNSCacheDelegate()

    private static func makeIconCache(name: String) -> NSCache<NSString, AnyObject> {
        let cache = NSCache<NSString, AnyObject>()
        cache.name = name
        cache.totalCostLimit = Int(bitPattern: UInt.max)  // REF-GRID-012: NSUIntegerMax
        if OSLog.default.isEnabled(type: .debug) {
            cache.delegate = cacheDelegate
        }
        return cache
    }

    /// The cost of an image in the caches: width × width × 32 (REF-GRID-012).
    private static func cost(_ image: AnyObject) -> Int {
        let width = (image as! CGImage).width
        return width * width * 32
    }

    /// The icon: the item's own, else the cache's (kept when `shouldCacheIcons`); on a miss it is read
    /// from the database and set when it arrives, and nil is returned meanwhile.
    @objc dynamic override var icon: AnyObject? {
        get {
            if let icon = _icon {
                return icon
            }
            guard let uuid = uuid as NSString? else { return nil }
            if let cached = Self.iconCache.object(forKey: uuid) {
                if _shouldCacheIcons {
                    _icon = cached
                }
                return cached
            }
            if !loadingLarge {
                loadingLarge = true
                loadImage(true) { [self] size, image in
                    iconLoaded(size: size, image: image, large: true)
                }
            }
            return nil
        }
        set {
            guard let uuid = uuid as NSString? else { return }
            guard let newValue else {
                Self.iconCache.removeObject(forKey: uuid)
                _icon = nil
                return
            }
            Self.iconCache.setObject(newValue, forKey: uuid, cost: Self.cost(newValue))
            _icon = _shouldCacheIcons ? newValue : nil
        }
    }

    @objc dynamic override var miniIcon: AnyObject? {
        get {
            if let icon = _miniIcon {
                return icon
            }
            guard let uuid = uuid as NSString? else { return nil }
            if let cached = Self.miniIconCache.object(forKey: uuid) {
                if _shouldCacheIcons {
                    _miniIcon = cached
                }
                return cached
            }
            if !loadingMini {
                loadingMini = true
                loadImage(false) { [self] size, image in
                    iconLoaded(size: size, image: image, large: false)
                }
            }
            return nil
        }
        set {
            guard let uuid = uuid as NSString? else { return }
            guard let newValue else {
                // Unlike the large icon, the item's own mini icon is kept.
                Self.miniIconCache.removeObject(forKey: uuid)
                return
            }
            Self.miniIconCache.setObject(newValue, forKey: uuid, cost: Self.cost(newValue))
            _miniIcon = _shouldCacheIcons ? newValue : nil
        }
    }

    @objc override var iconForStorage: AnyObject? { _icon }
    @objc override var miniIconForStorage: AnyObject? { _miniIcon }

    /// An icon read from the database, on the main queue: used when the item has none of its own, or
    /// when its size is the requested one; otherwise (or when nothing was stored) the icons are
    /// generated again at the requested sizes (REF-GRID-012).
    private func iconLoaded(size: UInt, image: AnyObject?, large: Bool) {
        let stored: AnyObject? = large ? iconForStorage : miniIconForStorage
        let requested = large ? largeIconSize : miniIconSize
        if image == nil || (stored != nil && requested != size) {
            if !reloadingFromDisk {
                reloadingFromDisk = true
                _retrieveImageOfLargeSize(largeIconSize, andMiniSize: miniIconSize, force: true)
            }
        } else if large {
            icon = image
        } else {
            miniIcon = image
        }
        if large {
            loadingLarge = false
        } else {
            loadingMini = false
        }
    }

    /// Reads the large or the mini icon from the database on the database queue and calls `block`
    /// on the main queue with its size and image, (0, nil) when there is none.
    @objc(loadImage:block:)
    func loadImage(_ large: Bool, block: @escaping @convention(block) (UInt, AnyObject?) -> Void) {
        let snapshot = snapshotForStorage(true, deepCopy: false)
        weak let storage = storage
        let completion = LPCompletionBlock { _ in block(0, nil) }
        storage?.addBlockToDatabaseQueue {
            completion.invalidate()
            storage?._loadImage(large, fromApp: snapshot, withBlock: block)
        }
    }

    /// Requests the icons at these pixel sizes; does nothing when they are the last requested ones.
    @objc(retrieveImageOfLargeSize:andMiniSize:)
    func retrieveImageOfLargeSize(_ large: UInt, andMiniSize mini: UInt) {
        _retrieveImageOfLargeSize(large, andMiniSize: mini, force: false)
    }

    /// Records the sizes and generates the icons on the information queue: the bookmark is resolved,
    /// then the images are made from the app's URL and set on the main queue (REF-GRID-012).
    @objc(_retrieveImageOfLargeSize:andMiniSize:force:)
    func _retrieveImageOfLargeSize(_ large: UInt, andMiniSize mini: UInt, force: Bool) {
        guard force || largeIconSize != large || miniIconSize != mini else { return }
        largeIconSize = large
        miniIconSize = mini
        let count = loadingCounter.add(1, ordering: .sequentiallyConsistent).newValue
        let request = UncheckedBox(self)
        LPRunnable.application_info_queue.async {
            let runnable = request.value
            guard runnable.loadingCounter.load(ordering: .sequentiallyConsistent) == count else { return }
            runnable.resolveURLFromBookMark(false) { url in
                guard runnable.loadingCounter.load(ordering: .sequentiallyConsistent) == count else { return }
                let resolved = UncheckedBox(url)
                LPRunnable.application_info_queue.async {
                    let url = resolved.value?.resolvingSymlinksInPath()
                    guard runnable.loadingCounter.load(ordering: .sequentiallyConsistent) == count else { return }
                    Logger().info("Generating image \(large) \(mini) for \(url?.path ?? "(null)")")
                    runnable.loadImagesFromURL(url, mini: mini, large: large) { largeImage, miniImage in
                        let images = UncheckedBox((largeImage, miniImage))
                        DispatchQueue.main.async {
                            let (largeImage, miniImage) = images.value
                            if largeImage != nil {
                                runnable.icon = largeImage
                            }
                            if miniImage != nil {
                                runnable.miniIcon = miniImage
                            }
                            if largeImage != nil || miniImage != nil {
                                runnable.updateImageStorage()
                            }
                            runnable.reloadingFromDisk = false
                        }
                    }
                }
            }
        }
    }

    /// Makes the large and the mini icon from the app at `url`; a runnable that is not an app has none.
    @objc(loadImagesFromURL:mini:large:images:)
    func loadImagesFromURL(_ url: URL?, mini: UInt, large: UInt,
                           images block: @escaping @convention(block) (AnyObject?, AnyObject?) -> Void) {
        block(nil, nil)
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

import Foundation
import LaunchPadPrivate
import SQLite3
import os

/// An application bundle found by a scan (REF-LAYOUT-003).
@objc(LPApp)
class LPApp: LPRunnable, @unchecked Sendable {
    /// Finds out whether `url` is an app and reads what Launchpad keeps about it; nil when it is not
    /// an app. Runs on the scanning queue.
    @objc(initWithURL:forScan:)
    override init?(url: URL, forScan scan: UInt32) {
        super.init(url: url, forScan: scan)
        if !_collectApplicationInfoForURL(url) {
            return nil
        }
    }

    /// Decodes `bundleid` after the `LPRunnable` columns.
    @objc(initWithSQLStatement:withColumn:)
    required init?(sqlStatement statement: OpaquePointer, withColumn column: UnsafeMutablePointer<Int32>) {
        super.init(sqlStatement: statement, withColumn: column)
        if let text = sqlite3_column_text(statement, column.pointee) {
            bundleID = String(cString: text)
        }
        column.pointee += 1
        // Here the original moves the last URL of a few apps renamed by older systems; that
        // migration is not done (design, omitted cases).
    }

    required init(forCopy: ()) {
        super.init(forCopy: ())
    }

    @objc(snapshotForStorage:deepCopy:)
    override func snapshotForStorage(_ forStorage: Bool, deepCopy: Bool) -> LPItem {
        super.snapshotForStorage(forStorage, deepCopy: deepCopy)
    }

    @objc override var isApp: Bool { true }
    @objc override var resolvesBookmarks: Bool { true }
    @objc var hasExtraPlugin: Bool { flags & 0x80 != 0 }

    @objc(updateInfoFromRunnable:)
    override func updateInfoFromRunnable(_ runnable: LPRunnable) {
        guard runnable is LPApp else { return }
        let hadExtraPlugin = hasExtraPlugin
        super.updateInfoFromRunnable(runnable)
        if hadExtraPlugin != hasExtraPlugin {
            NotificationCenter.default.post(name: Notification.Name("LPAppDockPluginChangedNotification"), object: self)
        }
    }

    // MARK: Reading the bundle

    private static let nameKeys: [URLResourceKey] = [.localizedNameKey, .isSymbolicLinkKey, .isAliasFileKey]
    private static let detailKeys: [URLResourceKey] = [
        .contentModificationDateKey,
        URLResourceKey(_kCFURLApplicationCategoriesKey as String),
        URLResourceKey(_kCFURLApplicationIsBetaKey as String),
    ]

    /// REF-LAYOUT-003: resolves a symbolic link or alias, reads the Info.plist, checks that it is a
    /// supported application, and fills in title, bundle ID, version, category, modification date,
    /// bookmark, last URL and flags.
    @objc(_collectApplicationInfoForURL:)
    func _collectApplicationInfoForURL(_ url: URL) -> Bool {
        let path = url.path
        let names = (try? (url as NSURL).resourceValues(forKeys: Self.nameKeys)) ?? [:]
        let isAlias = (names[.isAliasFileKey] as? NSNumber)?.boolValue ?? false
        let isSymlink = (names[.isSymbolicLinkKey] as? NSNumber)?.boolValue ?? false
        var target = url
        if isSymlink {
            target = url.resolvingSymlinksInPath()
        } else if isAlias,
                  let bookmark = try? NSURL.bookmarkData(withContentsOf: url),
                  let resolved = try? NSURL(resolvingBookmarkData: bookmark, options: NSURL.BookmarkResolutionOptions(rawValue: 0x10100),
                                            relativeTo: nil, bookmarkDataIsStale: nil) as URL {
            target = resolved
        }

        guard let info = CFBundleCopyInfoDictionaryForURL(target as CFURL) as NSDictionary?, info.count != 0 else {
            return false
        }
        bundleID = info[kCFBundleIdentifierKey as String] as? String
        _lastKnownVersion = versionFromInfoDictionary(info)

        let supportedFormatKey = URLResourceKey(_kCFURLApplicationHasSupportedFormatKey as String)
        guard let kind = try? (target as NSURL).resourceValues(forKeys: [.isApplicationKey, supportedFormatKey]) else {
            return false
        }
        guard (kind[.isApplicationKey] as? NSNumber)?.boolValue == true else {
            return false
        }
        guard (kind[supportedFormatKey] as? NSNumber)?.boolValue == true else {
            return false
        }

        var name = names[.localizedNameKey] as? String
        if let localized = name, (localized as NSString).pathExtension == "app" {
            name = (localized as NSString).deletingPathExtension
        }
        _title = name
        guard let title = _title else {
            return false
        }
        if (bundleID ?? "").isEmpty {
            bundleID = info[kCFBundleNameKey as String] as? String
            NSLog("%@: No CFBundleIdentifier. Using CFBundleName instead %@", path, bundleID ?? "(null)")
            if (bundleID ?? "").isEmpty {
                bundleID = title
                let executable = info[kCFBundleExecutableKey as String] as? String
                let iconFile = info[_kCFBundleIconFileKey as String] as? String
                if executable == "run.sh", iconFile == "shortcut.icns" {
                    _categoryUTI = "public.app-category.games"
                }
            }
            if (bundleID ?? "").isEmpty {
                bundleID = nil
                    return false
            }
        }

        let details = (try? (target as NSURL).resourceValues(forKeys: Self.detailKeys)) ?? [:]
        let categories = details[Self.detailKeys[1]] as? [String] ?? []
        let isBeta = (details[Self.detailKeys[2]] as? NSNumber)?.boolValue ?? false
        if let category = categories.first {
            _categoryUTI = uniqueCategoryString(category)
        }
        if let date = details[.contentModificationDateKey] as? Date {
            _modificationTime = date.timeIntervalSinceReferenceDate
        }

        _bookmarkData = try? url.bookmarkData(options: URL.BookmarkCreationOptions(rawValue: 0x2000_0200),
                                              includingResourceValuesForKeys: nil, relativeTo: nil)
        guard _bookmarkData != nil else {
            return false
        }
        _lastURL = url
        hasMigratedLastURL = false
        _updateFlagsForURL(target, andBundleInfo: info)
        if isSymlink {
            flags = flags | 0x10
        }
        if isAlias {
            flags = flags | 0x20
        }
        if isBeta {
            flags = flags | 0x800
        } else if flags & 0x1 == 0 {
            let record = try? LSApplicationRecord(url: url, allowPlaceholder: false)
            if record?.isWebApp == true {
                flags = flags | 0x1000
            }
            if bundleID?.hasPrefix("com.apple.shortcuts.droplet") == true {
                flags = flags | 0x2000
            }
        }
        return true
    }

    /// Sets the UI element (0x8) and Dock tile plug-in (0x80) bits from the Info.plist, after the
    /// store and uninstallability bits.
    @objc(_updateFlagsForURL:andBundleInfo:)
    func _updateFlagsForURL(_ url: URL, andBundleInfo bundleInfo: NSDictionary?) {
        var newFlags = flags
        _updateFlags(&newFlags, forUninstalabilityAtURL: url)
        let info = bundleInfo ?? (CFBundleCopyInfoDictionaryForURL(url as CFURL) as NSDictionary?)
        // `boolValue` of the value, when it has one.
        func boolValue(_ key: String) -> Bool {
            switch info?[key] {
            case let number as NSNumber: number.boolValue
            case let string as NSString: string.boolValue
            default: false
            }
        }
        if boolValue("NSBGOnly") || boolValue("LSBackgroundOnly") || boolValue("LSUIElement") || boolValue("NSUIElement") {
            newFlags |= 0x8
        } else {
            newFlags &= ~0x8
        }
        let plugIn = info?["NSDockTilePlugIn"] as? String
        if (plugIn ?? "").isEmpty || boolValue("NSDockTilePlugInMenuOnly") {
            newFlags &= ~0x80
        } else {
            newFlags |= 0x80
        }
        flags = newFlags
    }

    /// The store bit (0x1): a Mac App Store receipt in the bundle. The uninstallable bit (0x4) comes
    /// from a Dock-internal service the original asks here; it stays clear (design, omitted cases).
    @objc(_updateFlags:forUninstalabilityAtURL:)
    func _updateFlags(_ flags: UnsafeMutablePointer<UInt64>, forUninstalabilityAtURL url: URL) {
        let receipt = (url.path as NSString).appendingPathComponent("Contents/_MASReceipt/receipt")
        let isStore: UInt64 = FileManager.default.fileExists(atPath: receipt) ? 1 : 0
        flags.pointee = flags.pointee & ~0x1 | isStore
        flags.pointee &= ~0x4
    }

    /// Makes the large icon, then the mini icon, of the app at `url` from its LaunchServices binding
    /// with IconServices (REF-GRID-012); both nil when there is no binding. Runs on the information
    /// queue.
    @objc(loadImagesFromURL:mini:large:images:)
    override func loadImagesFromURL(_ url: URL?, mini: UInt, large: UInt,
                                    images block: @escaping @convention(block) (AnyObject?, AnyObject?) -> Void) {
        guard let url, let binding = _LSBindingCreateWithURL(nil, url as CFURL) else {
            block(nil, nil)
            return
        }
        let largeImage = Self.icon(of: binding, size: large)
        let miniImage = Self.icon(of: binding, size: mini)
        block(largeImage, miniImage)
    }

    /// The binding's icon at `size` × `size` pixels, drawn with the copy operation into a bitmap.
    private static func icon(of binding: CFTypeRef, size: UInt) -> CGImage? {
        let side = Int(size)
        return bitmapImage(sRGB: true, width: side, height: side, tag: 0) { context in
            context.saveGState()
            CGContextSetCompositeOperation(context, 1)
            if let image = ISCreateCGImageFromBindingWithSizeScaleAndOptions(binding, CGSize(width: side, height: side), 1, nil) {
                context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            } else {
                Logger().error("Failed to create an icon image")
            }
            context.restoreGState()
            context.flush()
        }
    }
}

// MARK: - LPStorage

extension LPApp {
    @objc override var storageType: Int { 4 }
    @objc override var storageTable: String? { "apps" }

    @objc override var storageCreationProperties: [String]? {
        ["title", "bundleIdentifier", "storeID", "modificationTime", "_bookmarkData"]
    }

    @objc override func storageColumnForProperty(_ property: String) -> String? {
        let columns = [
            "bundleIdentifier": "bundleid",
            "storeID": "storeid",
            "modificationTime": "moddate",
            "_bookmarkData": "bookmark",
        ]
        return columns[property] ?? super.storageColumnForProperty(property)
    }

    /// The original writes the icon and category rows again after `LPRunnable` already did.
    @objc(insertIntoStorage:parent:withOrder:)
    override func insertIntoStorage(_ storage: AnyObject, parent parentUUID: String, withOrder order: Int) {
        super.insertIntoStorage(storage, parent: parentUUID, withOrder: order)
        let storage = storage as! LPStorage
        storage._updateImageStorageForItem(self)
        storage._updateCategoryStorageForItem(self, withCategory: categoryUTI)
    }
}

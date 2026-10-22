import Foundation
import LaunchPadPrivate
import UniformTypeIdentifiers

/// Finds the apps of all sources and keeps the two roots: the layout's, and the one holding old
/// versions of apps (REF-LAYOUT-003).
///
/// Thread confinement: the roots, the caches and the sources are used on the main thread. Directory
/// scanning and reading bundles run on `scanningQueue`; each app found goes back to the main thread
/// before it is matched and cached.
@objc(LPAppManager)
final class LPAppManager: NSObject, @unchecked Sendable {
    var _storage: LPStorage?
    var lproot: LPRoot?
    var lpversroot: LPRoot?
    var rootWaitingBlocks: NSMutableArray?
    var _sources = NSMutableArray(capacity: 0)
    var sourcesByUUID = NSMutableDictionary(capacity: 0)
    /// Bundle ID → set of runnables.
    var runnablesByBundleID: NSMutableDictionary?
    /// uuid → app.
    var appsByUUID: NSMutableDictionary?
    /// Bundle ID → array of old versions, oldest first.
    var stashedVersionApps: NSMutableDictionary?
    var appPathsBeingProcessed = NSMutableSet(capacity: 0)
    var appVersionExceptions: NSSet?
    var scanningQueue = ECLimitQueue(name: "LPAppManager-scanning-queue")
    var scanIdentifier: UInt32 = 0
    let readOnly: Bool
    var stillScanning = false
    var addingSources = false

    static let runnableAddedNotification = Notification.Name("kLPAppManagerRunnableAdded")
    static let runnableDeletedNotification = Notification.Name("kLPAppManagerRunnableDeleted")
    static let runnableKey = "kLPAppManagerRunnableKey"

    nonisolated(unsafe) private static var bringupContext = 0
    /// Set by unit tests before the controller's startup takes it (grid-tree design decision 2).
    nonisolated(unsafe) static var shared: LPAppManager?

    /// The manager of this process's database (REF-LAYOUT-001, REF-DEV-002), made on first use.
    @objc class func sharedManager() -> LPAppManager? {
        if let shared {
            return shared
        }
        var buffer = [CChar](repeating: 0, count: 1024)
        let length = confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count)
        var directory: String?
        if length > 0, length <= buffer.count {
            directory = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } + "io.github.wljf817.LaunchPad.launchpad/db"
        }
        let databasePath = ((directory ?? "") as NSString).appendingPathComponent("db")
        let defaults = UserDefaults.standard
        let fileManager = FileManager.default
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        if defaults.bool(forKey: "ResetLaunchPad"), os_variant_allows_internal_security_policies("io.github.wljf817.LaunchPad") {
            defaults.removeObject(forKey: "ResetLaunchPad")
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
            try? fileManager.removeItem(atPath: databasePath)
        }
        if let directory {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue {
                try? fileManager.setAttributes(attributes, ofItemAtPath: (directory as NSString).deletingLastPathComponent)
            } else {
                if fileManager.fileExists(atPath: directory) {
                    try? fileManager.removeItem(atPath: (directory as NSString).deletingLastPathComponent)
                }
                do {
                    try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: attributes)
                } catch {
                    NSLog("LaunchPad: Failed to create LaunchPad database path: %@", String(describing: error))
                }
            }
        }
        shared = LPAppManager(atPath: databasePath, readOnly: false)
        return shared
    }

    /// Opens the database at `path`. When it has been read, on the main thread: takes both roots,
    /// sets up the sources (which start scanning), and answers `roots:`.
    @objc(initAtPath:readOnly:)
    init?(atPath path: String, readOnly: Bool) {
        self.readOnly = readOnly
        stillScanning = true
        super.init()
        let manager = UncheckedBox(self)
        _storage = LPStorage(path: path, readOnly: readOnly) { root, versionsRoot, sources in
            let values = UncheckedBox((root, versionsRoot, sources))
            DispatchQueue.main.async {
                let manager = manager.value
                let (root, versionsRoot, sources) = values.value
                manager.lproot = root
                manager.lpversroot = versionsRoot
                manager._processRootPages()
                manager._processInitialSources(sources)
                for case let block as AnyObject in manager.rootWaitingBlocks ?? [] {
                    unsafeBitCast(block, to: (@convention(block) (LPRoot?, LPRoot?) -> Void).self)(root, versionsRoot)
                }
                manager.rootWaitingBlocks = nil
                // The App Store connection, Screen Time and Siri icons are set up here (phase 6).
            }
        }
        if let layoutPath = launchPadBundle.path(forResource: "LaunchPadLayout", ofType: "plist"),
           let template = NSDictionary(contentsOfFile: layoutPath),
           let exceptions = (template["launchpad"] as? NSDictionary)?["version_exceptions"] as? [Any], !exceptions.isEmpty {
            appVersionExceptions = NSSet(array: exceptions)
        }
    }

    @objc var storage: LPStorage? { _storage }
    @objc var readonly: Bool { readOnly }
    @objc var sources: [LPAppSource] { _sources.copy() as! [LPAppSource] }

    /// KVO-observable: true until every source has completed its first bring-up.
    @objc dynamic var sourcesStillScanning: Bool {
        get { stillScanning }
        set { stillScanning = newValue }
    }

    /// Calls `block` on the main thread with both roots, once they have been read.
    @objc(roots:)
    func roots(_ block: @escaping @convention(block) (LPRoot?, LPRoot?) -> Void) {
        if lproot == nil {
            if rootWaitingBlocks == nil {
                rootWaitingBlocks = NSMutableArray(capacity: 0)
            }
            rootWaitingBlocks?.add(block as AnyObject)
        } else {
            let call = UncheckedBox(block)
            DispatchQueue.main.async { [self] in
                call.value(lproot, lpversroot)
            }
        }
    }

    // MARK: Startup

    /// Caches the runnables of both roots and removes duplicates (two items for the same path:
    /// the one directly on a page wins over one in a folder, otherwise the first wins). Old
    /// versions in the second root's hidden page are cached as stashed.
    @objc func _processRootPages() {
        guard let lproot, let lpversroot else { return }
        // The original compares the stored localization and region with the current ones here and
        // updates the titles when they changed (design, omitted cases).
        let dbInfo = storage?.dbInfo
        let updatedForROSP = (dbInfo?["UpdatedForROSP"] as AnyObject?)?.boolValue ?? false
        let updatedForiTunesSplit = (dbInfo?["UpdatedForiTunesSplit"] as AnyObject?)?.boolValue ?? false

        let runnables = NSMutableArray()
        let byPath = NSMutableDictionary()
        let duplicates = NSMutableSet()
        let visit: (LPItem, UnsafeMutablePointer<ObjCBool>) -> Void = { [self] item, _ in
            guard let runnable = item as? LPRunnable else { return }
            // Downloading apps are cached by store ID here in the original (phase 6).
            let path = runnable.lastURL?.path
            _cacheRunnable(runnable)
            runnables.add(runnable)
            guard let path else { return }
            if let previous = byPath[path] as? LPRunnable {
                if runnable.parentPage === runnable.parentContainer, previous.parentPage !== previous.parentContainer {
                    duplicates.add(previous)
                    byPath[path] = runnable
                } else {
                    duplicates.add(runnable)
                }
            } else {
                byPath[path] = runnable
            }
        }
        lproot.iterateChildren(visit)
        lproot.purgatory.iterateChildren(visit)
        for case let duplicate as LPRunnable in duplicates {
            guard let parent = duplicate.parentContainer else { continue }
            parent.children.remove(duplicate)
            Self.removeIfEmpty(parent)
        }
        lpversroot.purgatory.iterateChildren { [self] item, _ in
            if let runnable = item as? LPRunnable {
                _cacheRunnable(runnable)
                _cacheStashedApp(runnable)
            }
        }
        // The App Store is asked for updates here (phase 6).

        if !(updatedForROSP && updatedForiTunesSplit) {
            // The original also migrates apps of older systems before this completes (design,
            // omitted cases); the block runs when the last reference to it is released.
            _ = LPCompletionBlock { [weak self] _ in
                self?.storage?.setDBInfoValue(kCFBooleanTrue, forKey: "UpdatedForROSP")
                self?.storage?.setDBInfoValue(kCFBooleanTrue, forKey: "UpdatedForiTunesSplit")
            }
        }
    }

    /// Removes a page or folder left empty, and those above it, but not the root's last page.
    private static func removeIfEmpty(_ container: LPItem & LPItemContainer) {
        guard let root = container.root, container !== root, container !== root.purgatory, container.isEmpty,
              let parent = container.parentContainer else { return }
        let siblings = parent.children
        if parent !== root || siblings.count != 1 {
            siblings.removeObject(identicalTo: container)
            removeIfEmpty(parent)
        }
    }

    /// Adds the sources in the order 1, 2, 6, 3, 4, 5, reusing those read from the database.
    @objc(_processInitialSources:)
    func _processInitialSources(_ stored: [LPAppSource]?) {
        addingSources = true
        let byLocation = NSMutableDictionary(capacity: 3)
        for source in stored ?? [] where source.location != 0 {
            byLocation[source.location] = source
        }
        for location in [1, 2, 6, 3, 4, 5] {
            _addSource(byLocation[location] as? LPAppSource ?? LPAppSource(forLocation: location))
        }
        addingSources = false
        if !isStillScanning() {
            sourcesStillScanning = false
        }
    }

    @objc(_addSource:)
    func _addSource(_ source: LPAppSource?) {
        guard let source else { return }
        willChangeValue(forKey: "sources")
        source.owningManager = self
        _sources.add(source)
        if let uuid = source.uuid {
            sourcesByUUID[uuid] = source
        }
        source.addObserver(self, forKeyPath: "initialBringupComplete", options: [], context: &Self.bringupContext)
        storage?.registerAppSourceWithStorage(source)
        didChangeValue(forKey: "sources")
    }

    /// True while sources are being added, or while any source has not completed its first
    /// bring-up (or there are none).
    @objc func isStillScanning() -> Bool {
        if addingSources {
            return true
        }
        for case let source as LPAppSource in _sources where !source.initialBringupComplete {
            return true
        }
        return _sources.count == 0
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        guard context == &Self.bringupContext else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        let scanning = isStillScanning()
        if scanning != sourcesStillScanning {
            sourcesStillScanning = scanning
        }
    }

    // MARK: Scanning

    /// A path inside an invisible folder or a package cannot hold apps.
    @objc(pathValidForApplications:)
    func pathValidForApplications(_ path: String) -> Bool {
        if path == "/" {
            return true
        }
        guard !path.isEmpty, !(path as NSString).lastPathComponent.hasPrefix(".") else { return false }
        let isPackage = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]).isPackage
        if isPackage == true {
            return false
        }
        return pathValidForApplications((path as NSString).deletingLastPathComponent)
    }

    /// Scans `path` on the scanning queue. Options: 1 recurse, 2 the path is an app itself, 8 check
    /// afterwards for known apps under the path that were not found, 0x10 apps found were added by
    /// the user. `completion` runs on the main thread once all work for the scan has finished.
    @objc(scanForApplicationsAtPath:fromSource:options:completion:)
    func scanForApplications(atPath path: String?, fromSource source: LPAppSource?, options: UInt,
                             completion: @escaping @convention(block) (UInt32) -> Void) {
        let checkMissing = options & 8 != 0
        weak let manager = self
        let context = LPCompletionBlock { identifier in
            guard checkMissing, let manager, let path else {
                completion(identifier)
                return
            }
            let afterCheck = LPCompletionBlock { completion($0) }
            afterCheck.identifier = identifier
            manager._checkForMissingApplications(atPath: path, withLatestScanIdentifier: identifier, withCompletion: afterCheck)
        }
        if options & 0x10 != 0 {
            context.userinfo = ["userAdded": true]
        }
        let pathIsApp = options & 2 != 0
        let recurse = options & 1 != 0
        let work = UncheckedBox((self, path, source, context))
        scanningQueue.async {
            let (manager, path, source, context) = work.value
            guard let path, manager.pathValidForApplications((path as NSString).deletingLastPathComponent) else { return }
            let url = URL(fileURLWithPath: path)
            let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
            manager.scanIdentifier += 1
            context.identifier = manager.scanIdentifier
            let resolvedPath = ((path as NSString).resolvingSymlinksInPath as NSString).standardizingPath
            if pathIsApp {
                var isLink: ObjCBool = false
                var stop: ObjCBool = false
                manager._processScannedApplicationURL(url as CFURL, unresolvedSymlinkPath: nil, fromSource: source,
                                                      isLink: &isLink, preventRecursion: &stop, withContext: context)
                if isLink.boolValue {
                    manager._processScannedApplicationURL(URL(fileURLWithPath: resolvedPath) as CFURL, unresolvedSymlinkPath: path,
                                                          fromSource: source, isLink: &isLink, preventRecursion: &stop,
                                                          withContext: context)
                    if !isLink.boolValue, !stop.boolValue, recurse {
                        manager._scanForApplications(atPath: resolvedPath, symlinkUnresolvedPath: path, fromSource: source,
                                                     linksFollowed: NSMutableSet(object: resolvedPath), recurse: true,
                                                     withContext: context)
                    }
                } else if !stop.boolValue, recurse, !isPackage {
                    manager._scanForApplications(atPath: resolvedPath, symlinkUnresolvedPath: path, fromSource: source,
                                                 linksFollowed: nil, recurse: recurse, withContext: context)
                }
            } else if !isPackage {
                manager._scanForApplications(atPath: resolvedPath, symlinkUnresolvedPath: path, fromSource: source,
                                             linksFollowed: nil, recurse: recurse, withContext: context)
            }
        }
    }

    /// Enumerates `path`, skipping invisible entries and package contents. Each entry is examined;
    /// a symbolic link is examined again at its target, but a linked folder is not entered.
    @objc(_scanForApplicationsAtPath:symlinkUnresolvedPath:fromSource:linksFollowed:recurse:withContext:)
    func _scanForApplications(atPath path: String, symlinkUnresolvedPath unresolvedPath: String?, fromSource source: LPAppSource?,
                              linksFollowed: NSMutableSet?, recurse: Bool, withContext context: LPCompletionBlock) {
        let keys = [URLResourceKey.nameKey, .isPackageKey, .isDirectoryKey, .isSymbolicLinkKey] as CFArray
        let options = CFURLEnumeratorOptions(rawValue: (recurse ? 1 : 0) | 0x1a)
        guard let enumerator = CFURLEnumeratorCreateForDirectoryURL(nil, URL(fileURLWithPath: path) as CFURL, options, keys) else {
            return
        }
        let linksFollowed = linksFollowed ?? NSMutableSet()
        while true {
            var next: Unmanaged<CFURL>?
            var error: Unmanaged<CFError>?
            let result = CFURLEnumeratorGetNextURL(enumerator, &next, &error)
            if result == .end {
                break
            }
            if result == .error {
                if let error = error?.takeUnretainedValue() {
                    NSLog("Error iterating %@. %@", path, String(describing: error))
                }
                continue
            }
            guard result == .success, let entry = next?.takeUnretainedValue() else { continue }
            autoreleasepool {
                var isLink: ObjCBool = false
                var stop: ObjCBool = false
                let entryPath = (entry as URL).path
                if (entryPath as NSString).lastPathComponent.hasPrefix(".") {
                    stop = true
                } else {
                    var unresolvedEntryPath: String?
                    if let unresolvedPath {
                        let relative = (entryPath as NSString).substring(from: (path as NSString).length + 1)
                        unresolvedEntryPath = (unresolvedPath as NSString).appendingPathComponent(relative)
                    }
                    _processScannedApplicationURL(entry, unresolvedSymlinkPath: unresolvedEntryPath, fromSource: source,
                                                  isLink: &isLink, preventRecursion: &stop, withContext: context)
                    if isLink.boolValue {
                        let target = ((entryPath as NSString).resolvingSymlinksInPath as NSString).standardizingPath
                        let linkPath = unresolvedEntryPath ?? entryPath
                        isLink = false
                        stop = false
                        _processScannedApplicationURL(URL(fileURLWithPath: target) as CFURL, unresolvedSymlinkPath: linkPath,
                                                      fromSource: source, isLink: &isLink, preventRecursion: &stop,
                                                      withContext: context)
                        if recurse, !stop.boolValue, !linksFollowed.contains(target) {
                            NSLog("Skipping symlink folder %@ %@", linkPath, target)
                        }
                    }
                }
                if stop.boolValue {
                    CFURLEnumeratorSkipDescendents(enumerator)
                }
            }
        }
    }

    /// Examines one entry (REF-LAYOUT-003): reports symbolic links through `isLink`, sets `stop`
    /// for entries not to descend into, and hands apps to `_source:atURL:withContext:`.
    @objc(_processScannedApplicationURL:unresolvedSymlinkPath:fromSource:isLink:preventRecursion:withContext:)
    func _processScannedApplicationURL(_ url: CFURL, unresolvedSymlinkPath unresolvedPath: String?, fromSource source: LPAppSource?,
                                       isLink: UnsafeMutablePointer<ObjCBool>?, preventRecursion stop: UnsafeMutablePointer<ObjCBool>?,
                                       withContext context: LPCompletionBlock) {
        let url = url as URL
        guard let values = try? (url as NSURL).resourceValues(forKeys: [.nameKey, .isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey, .isPackageKey]) else {
            return
        }
        let isDirectory = (values[.isDirectoryKey] as? NSNumber)?.boolValue ?? false
        let isAlias = (values[.isAliasFileKey] as? NSNumber)?.boolValue ?? false
        let isPackage = (values[.isPackageKey] as? NSNumber)?.boolValue ?? false
        let isSymlink = (values[.isSymbolicLinkKey] as? NSNumber)?.boolValue ?? false
        let regionCode = LPStorage.currentRegionCode
        let pathExtension = ((values[.nameKey] as? String ?? "") as NSString).pathExtension
        if isSymlink {
            isLink?.pointee = true
            return
        }
        if url.lastPathComponent.hasPrefix(".") {
            stop?.pointee = true
            return
        }
        if isAlias {
            guard Self.isApplicationAlias(url.path) else { return }
        } else {
            guard isDirectory else { return }
            if pathExtension.isEmpty {
                if isPackage {
                    stop?.pointee = true
                }
                return
            }
            let details = (try? (url as NSURL).resourceValues(forKeys: Self.hiddenKeys + [.contentTypeKey])) ?? [:]
            guard !Self.isHidden(details, regionCode: regionCode), let type = details[.contentTypeKey] as? UTType else { return }
            guard type.conforms(to: .application) else {
                if type.conforms(to: .bundle) {
                    stop?.pointee = true
                }
                return
            }
            stop?.pointee = true
        }
        let appURL = unresolvedPath.map { URL(fileURLWithPath: $0) } ?? url
        _source(source, atURL: appURL, withContext: context)
    }

    /// An alias counts as an app when its Finder type is one of the alias types of applications.
    private static func isApplicationAlias(_ path: String) -> Bool {
        var info = [UInt8](repeating: 0, count: 32)
        guard getxattr(path, "com.apple.FinderInfo", &info, 32, 0, XATTR_NOFOLLOW) > 7 else { return false }
        let type = String(bytes: info[0..<4], encoding: .macOSRoman)
        return ["acdp", "addp", "adrp", "fapa"].contains(type)
    }

    private static let supportedRegionsKey = URLResourceKey(_kCFURLApplicationSupportedRegionsKey as String)
    private static let hiddenBySystemKey = URLResourceKey("_NSURLIsHiddenBySystemKey")
    private static let hiddenKeys = [supportedRegionsKey, hiddenBySystemKey]

    /// Hidden: supported regions are declared and the region is not among them; otherwise the
    /// system's hidden flag (REF-LAYOUT-003).
    private static func isHidden(_ values: [URLResourceKey: Any], regionCode: String?) -> Bool {
        if let regions = values[supportedRegionsKey] as? [String] {
            return !regions.contains { $0 == regionCode }
        }
        return (values[hiddenBySystemKey] as? NSNumber)?.boolValue ?? false
    }

    /// Reads the app at `url` on the scanning queue, then matches it on the main thread.
    @objc(_source:atURL:withContext:)
    func _source(_ source: LPAppSource?, atURL url: URL, withContext context: LPCompletionBlock) {
        let values = (try? (url as NSURL).resourceValues(forKeys: Self.hiddenKeys + [URLResourceKey(_kCFURLApplicationIsBetaKey as String)])) ?? [:]
        guard !Self.isHidden(values, regionCode: LPStorage.currentRegionCode) else { return }
        let isBeta = (values[URLResourceKey(_kCFURLApplicationIsBetaKey as String)] as? NSNumber)?.boolValue ?? false
        guard let app = LPApp(url: url, forScan: context.identifier) else { return }
        if context.userinfo?["userAdded"] != nil {
            app.addedByUser = true
        }
        app.isBeta = isBeta
        let resolvedPath = (url.path as NSString).resolvingSymlinksInPath
        let work = UncheckedBox((self, app, context))
        DispatchQueue.main.async {
            let (manager, app, context) = work.value
            // Screen Time restrictions are set here (phase 6); without them no app is restricted.
            app.isRestricted = false
            guard !manager.appPathsBeingProcessed.contains(resolvedPath) else { return }
            manager.appPathsBeingProcessed.add(resolvedPath)
            manager._findExistingRunnableMatching(app, atPath: resolvedPath, resolveURLs: true) { existing, checked in
                let isException = app.bundleIdentifier.map { manager.appVersionExceptions?.contains($0) ?? false } ?? false
                if let existing {
                    manager._updateExistingRunnable(existing, withNewRunnable: app, context: context)
                } else if !app.addedByUser, !isException, let checked, checked.count != 0 {
                    let sorted = (checked.allObjects as NSArray).sortedArray { a, b in
                        manager.compareCandidates(a as? LPRunnable, b as? LPRunnable)
                    }
                    manager._newRunnbleFound(app, withExistingRunnable: sorted.first as? LPRunnable)
                } else {
                    manager._addNewRunnable(app)
                }
                manager.appPathsBeingProcessed.remove(resolvedPath)
            }
        }
    }

    /// Older versions first; at equal versions one kept as an old version sorts after one that is not.
    private func compareCandidates(_ a: LPRunnable?, _ b: LPRunnable?) -> ComparisonResult {
        let result = _LSVersionNumberCompare(a?.lastKnownVersion ?? LSVersionNumber(), b?.lastKnownVersion ?? LSVersionNumber())
        if result != .compareEqualTo {
            return ComparisonResult(rawValue: result.rawValue) ?? .orderedSame
        }
        if a?.root === lpversroot {
            return b?.root !== lpversroot ? .orderedDescending : .orderedSame
        }
        return .orderedAscending
    }

    // MARK: Matching

    /// Looks for a known runnable that is the same app: same class and bundle ID, or any app at the
    /// same path; when stored paths differ, the candidates' bookmarks are resolved. Calls `block`
    /// with the match (or nil) and the candidates checked.
    @objc(_findExistingRunnableMatching:atPath:resolveURLs:withExisting:)
    func _findExistingRunnableMatching(_ runnable: LPRunnable, atPath path: String?, resolveURLs: Bool,
                                       withExisting block: @escaping @convention(block) (LPRunnable?, NSMutableSet?) -> Void) {
        let candidates: NSMutableSet? = runnable.bundleIdentifier.flatMap {
            (runnablesByBundleID?[$0] as? NSMutableSet)?.mutableCopy() as? NSMutableSet
        }
        let checked = NSMutableSet()
        guard let path else {
            block(nil, nil)
            return
        }
        let paths = NSMapTable<LPRunnable, NSString>.strongToStrongObjects()
        let apps = appsByUUID?.allValues ?? []
        let candidateSet = candidates ?? NSMutableSet()
        for case let candidate as LPRunnable in candidateSet where candidate.isKind(of: type(of: runnable)) {
            if let candidatePath = candidate.lastURL?.path {
                paths.setObject(candidatePath as NSString, forKey: candidate)
            }
        }
        for case let app as LPRunnable in apps {
            if let appPath = app.lastURL?.path, (appPath as NSString).isEqual(to: path) {
                paths.setObject(appPath as NSString, forKey: app)
                candidateSet.add(app)
            }
        }
        _matchRunnable(runnable, withPath: path, toRunnables: candidateSet, checked: checked, withURLS: paths) { [self] found, checked in
            if found == nil, resolveURLs {
                _findExistingRunnableMatching(runnable, atPath: path, resolveURLs: false, withExisting: block)
            } else {
                block(found, checked)
            }
        }
    }

    /// Tries the candidates one at a time: a stored path equal to `path` matches; otherwise the
    /// candidate's bookmark is resolved and its target path compared. A candidate in the old-version
    /// root that no longer resolves is forgotten, and matching ends there without calling `block`.
    @objc(_matchRunnable:withPath:toRunnables:checked:withURLS:returnBlock:)
    func _matchRunnable(_ runnable: LPRunnable, withPath path: String, toRunnables candidates: NSMutableSet, checked: NSMutableSet,
                        withURLS paths: NSMapTable<LPRunnable, NSString>,
                        returnBlock block: @escaping @convention(block) (LPRunnable?, NSMutableSet?) -> Void) {
        guard let candidate = candidates.anyObject() as? LPRunnable else {
            block(nil, checked)
            return
        }
        let candidatePath = paths.object(forKey: candidate)
        checked.add(candidate)
        candidates.remove(candidate)
        if let candidatePath, candidatePath.isEqual(to: path) {
            block(candidate, checked)
            return
        }
        let work = UncheckedBox((self, runnable, candidate, candidates, checked, paths, block))
        candidate.resolveURLFromBookMark(true, updateVersion: true) { url, _ in
            DispatchQueue.global().async {
                let resolvedPath = (url?.path as NSString?)?.resolvingSymlinksInPath
                DispatchQueue.main.async {
                    let (manager, runnable, candidate, candidates, checked, paths, block) = work.value
                    if resolvedPath == nil, candidate.root === manager.lpversroot {
                        manager.forgetRunnable(candidate)
                        return
                    }
                    if isEqualToString(resolvedPath, path) {
                        block(candidate, checked)
                        return
                    }
                    manager._matchRunnable(runnable, withPath: path, toRunnables: candidates, checked: checked, withURLS: paths, returnBlock: block)
                }
            }
        }
    }

    // MARK: Versions

    /// A scan found an app already known: the known item takes the new information. When it is an
    /// old version, it may replace the copy in the layout if it is newer.
    @objc(_updateExistingRunnable:withNewRunnable:context:)
    func _updateExistingRunnable(_ existing: LPRunnable, withNewRunnable runnable: LPRunnable, context: LPCompletionBlock?) {
        _swapRunnable(existing, withRunnable: runnable, stashExisting: false)
        guard existing.root === lpversroot else { return }
        let version = existing.lastKnownVersion
        let apps = appsMatchingBundleID(existing.bundleIdentifier)
        let others = apps.isEmpty ? nil : NSMutableSet(array: apps)
        if let others, others.count != 0 {
            _checkForOlderAppsToReplace(others, withApp: existing, version: version, context: context)
        }
    }

    /// Compares one shown copy with the old version `app` at a time; the first that `app` is newer
    /// than takes its information (its own old state is kept as an old version) and `app` is
    /// forgotten.
    @objc(_checkForOlderAppsToReplace:withApp:version:context:)
    func _checkForOlderAppsToReplace(_ candidates: NSMutableSet, withApp app: LPRunnable, version: LSVersionNumber, context: LPCompletionBlock?) {
        while let candidate = candidates.anyObject() as? LPRunnable {
            if candidate !== app, !candidate.addedByUser, candidate.root !== lpversroot {
                let compare: @convention(block) (LSVersionNumber) -> Void = { [self] candidateVersion in
                    candidates.remove(candidate)
                    if _LSVersionNumberCompare(version, candidateVersion) == .compareGreaterThan {
                        _swapRunnable(candidate, withRunnable: app, stashExisting: true)
                        forgetRunnable(app)
                    } else {
                        _checkForOlderAppsToReplace(candidates, withApp: app, version: version, context: context)
                    }
                }
                if _LSVersionNumberCompare(candidate.lastKnownVersion, kLSVersionNumberNull) != .compareEqualTo {
                    compare(candidate.lastKnownVersion)
                } else {
                    candidate.resolveURLFromBookMark(true, updateVersion: true) { _, version in
                        compare(version)
                    }
                }
                return
            }
            candidates.remove(candidate)
        }
    }

    /// A new copy of an app already known (REF-LAYOUT-003): the newer wins; at equal versions the
    /// new one wins only from `/Applications`. The loser is kept as an old version.
    @objc(_newRunnbleFound:withExistingRunnable:)
    func _newRunnbleFound(_ runnable: LPRunnable, withExistingRunnable existing: LPRunnable?) {
        let existingVersion = existing?.lastKnownVersion ?? LSVersionNumber()
        switch _LSVersionNumberCompare(existingVersion, runnable.lastKnownVersion) {
        case .compareLessThan:
            if let existing {
                _swapRunnable(existing, withRunnable: runnable, stashExisting: true)
            }
        case .compareEqualTo:
            let newInApplications = runnable.lastURL?.path.hasPrefix("/Applications") ?? false
            let existingInApplications = existing?.lastURL?.path.hasPrefix("/Applications") ?? false
            if newInApplications, !existingInApplications, let existing {
                _swapRunnable(existing, withRunnable: runnable, stashExisting: true)
            } else {
                NSLog("Skipping %@ (%@) a version already present %@ (%@).", runnable, runnable.lastURL?.path ?? "", existing ?? "", existing?.lastURL?.path ?? "")
                _stashUnusedAppVersion(runnable)
            }
        case .compareGreaterThan:
            NSLog("Skipping %@ (%@) a newer version already present %@ (%@).", runnable, runnable.lastURL?.path ?? "", existing ?? "", existing?.lastURL?.path ?? "")
            _stashUnusedAppVersion(runnable)
        default:
            break
        }
    }

    /// `existing` takes the information of `runnable`; with `stash`, a copy of its old state is
    /// kept as an old version first.
    @objc(_swapRunnable:withRunnable:stashExisting:)
    func _swapRunnable(_ existing: LPRunnable, withRunnable runnable: LPRunnable, stashExisting stash: Bool) {
        if stash, let copy = existing.snapshotForStorage(false, deepCopy: false) as? LPRunnable {
            _stashUnusedAppVersion(copy)
        }
        let oldBundleID = existing.bundleIdentifier
        existing.updateInfoFromRunnable(runnable)
        if !isEqualToString(oldBundleID, existing.bundleIdentifier) {
            _bundleIDForRunnable(existing, changedFrom: oldBundleID, to: existing.bundleIdentifier)
        }
    }

    @objc(_stashUnusedAppVersion:)
    func _stashUnusedAppVersion(_ runnable: LPRunnable) {
        _cacheRunnable(runnable)
        _cacheStashedApp(runnable)
        lpversroot?.addItemToPurgatory(runnable)
    }

    /// A new app goes into the hidden page of the layout root, from where the layout places it.
    @objc(_addNewRunnable:)
    func _addNewRunnable(_ runnable: LPRunnable) {
        // A downloading App Store app with the same bundle ID takes it over here (phase 6).
        _cacheRunnable(runnable)
        lproot?.addItemToPurgatory(runnable)
        NotificationCenter.default.post(name: Self.runnableAddedNotification, object: self, userInfo: [Self.runnableKey: runnable])
    }

    // MARK: Caches

    @objc(_cacheRunnable:)
    func _cacheRunnable(_ runnable: LPRunnable) {
        let bundleID = runnable.bundleIdentifier
        var set = bundleID.flatMap { runnablesByBundleID?[$0] as? NSMutableSet }
        if runnablesByBundleID == nil {
            runnablesByBundleID = NSMutableDictionary(capacity: 0)
        }
        if let bundleID, set == nil {
            set = NSMutableSet(capacity: 0)
            runnablesByBundleID?[bundleID] = set
        }
        set?.add(runnable)
        if runnable is LPApp {
            if appsByUUID == nil {
                appsByUUID = NSMutableDictionary(capacity: 0)
            }
            appsByUUID?[runnable.uuid as Any] = runnable
            // Screen Time restrictions are refreshed here (phase 6).
        }
    }

    /// Keeps the old versions of each bundle ID sorted by version, oldest first.
    @objc(_cacheStashedApp:)
    func _cacheStashedApp(_ runnable: LPRunnable) {
        if stashedVersionApps == nil {
            stashedVersionApps = NSMutableDictionary(capacity: 0)
        }
        let key = runnable.bundleIdentifier as Any
        var versions = stashedVersionApps?[key] as? NSMutableArray
        if versions == nil {
            versions = NSMutableArray()
            stashedVersionApps?[key] = versions
        }
        guard let versions else { return }
        if versions.count == 0 {
            versions.add(runnable)
        } else {
            let index = versions.index(of: runnable, inSortedRange: NSRange(location: 0, length: versions.count), options: .insertionIndex) { a, b in
                let result = _LSVersionNumberCompare((a as? LPRunnable)?.lastKnownVersion ?? LSVersionNumber(),
                                                     (b as? LPRunnable)?.lastKnownVersion ?? LSVersionNumber())
                return ComparisonResult(rawValue: result.rawValue) ?? .orderedSame
            }
            versions.insert(runnable, at: index)
        }
    }

    @objc(_bundleIDForRunnable:changedFrom:to:)
    func _bundleIDForRunnable(_ runnable: LPRunnable, changedFrom oldBundleID: String?, to newBundleID: String?) {
        let oldSet = oldBundleID.flatMap { runnablesByBundleID?[$0] as? NSMutableSet }
        var newSet = newBundleID.flatMap { runnablesByBundleID?[$0] as? NSMutableSet }
        oldSet?.remove(runnable)
        if let oldBundleID, oldSet?.count ?? 0 == 0 {
            runnablesByBundleID?.removeObject(forKey: oldBundleID)
        }
        if let newBundleID, newSet == nil {
            newSet = NSMutableSet(capacity: 0)
            runnablesByBundleID?[newBundleID] = newSet
        }
        newSet?.add(runnable)
    }

    @objc(appsMatchingBundleID:)
    func appsMatchingBundleID(_ bundleID: String?) -> [LPRunnable] {
        guard let bundleID else { return [] }
        return (runnablesByBundleID?[bundleID] as? NSMutableSet)?.allObjects as? [LPRunnable] ?? []
    }

    /// Drops a runnable from the caches; an old version also leaves its root.
    @objc(forgetRunnable:)
    func forgetRunnable(_ runnable: LPRunnable) {
        let bundleID = runnable.bundleIdentifier
        let set = bundleID.flatMap { runnablesByBundleID?[$0] as? NSMutableSet }
        if runnable is LPApp, let uuid = runnable.uuid {
            appsByUUID?.removeObject(forKey: uuid)
        }
        set?.remove(runnable)
        if let set, set.count == 0 {
            // The original passes the set, not the bundle ID, as the key, so the entry stays.
            runnablesByBundleID?.removeObject(forKey: set)
        }
        guard runnable.root === lpversroot else { return }
        if let bundleID, let versions = stashedVersionApps?[bundleID] as? NSMutableArray {
            let index = versions.indexOfObjectIdentical(to: runnable)
            if index != NSNotFound {
                versions.removeObject(at: index)
                if versions.count == 0 {
                    stashedVersionApps?.removeObject(forKey: bundleID)
                }
            }
        }
        runnable.parentContainer?.children.remove(runnable)
        // Screen Time is told here (phase 6).
    }

    // MARK: Missing apps

    /// After a full scan of `path`: every known app under it that this scan did not see is checked.
    @objc(_checkForMissingApplicationsAtPath:withLatestScanIdentifier:withCompletion:)
    func _checkForMissingApplications(atPath path: String, withLatestScanIdentifier scan: UInt32, withCompletion completion: LPCompletionBlock) {
        let apps = (appsByUUID?.allValues as? [LPRunnable]) ?? []
        var missing: [LPRunnable] = []
        for app in apps {
            guard let appPath = app.lastURL?.path, appPath.hasPrefix(path), app.lastScan != scan else { continue }
            // Apps inside a downloading app are skipped here in the original (phase 6).
            missing.append(app)
        }
        for app in missing {
            _checkRunnablePossibleMissingRunnable(app, withCompletion: completion)
        }
    }

    /// Resolves the bookmark of an app not seen by a scan. Gone, in a trash, or renamed to start
    /// with `.`: an old version is forgotten; a shown app is replaced by its newest old version, or
    /// announced as deleted when there is none.
    @objc(_checkRunnablePossibleMissingRunnable:withCompletion:)
    func _checkRunnablePossibleMissingRunnable(_ runnable: LPRunnable, withCompletion completion: LPCompletionBlock) {
        let work = UncheckedBox((self, completion))
        runnable.resolveURLFromBookMark(true) { url in
            let (manager, _) = work.value
            if let url, !url.lastPathComponent.hasPrefix(".") {
                let components = url.pathComponents
                guard components.contains(".Trashes") || components.contains(".Trash") else {
                    return
                }
                NSLog("Missing/moved item found in trash. %@", url.path)
            } else if let url {
                NSLog("Missing/moved item found with . prefix. %@. Will not be re-added.", url.path)
            }
            if runnable.root === manager.lpversroot {
                manager.forgetRunnable(runnable)
                return
            }
            let versions = (runnable is LPApp) ? runnable.bundleIdentifier.flatMap { manager.stashedVersionApps?[$0] as? NSMutableArray } : nil
            if let newest = versions?.lastObject as? LPRunnable, versions?.count ?? 0 != 0 {
                manager._swapRunnable(runnable, withRunnable: newest, stashExisting: false)
            } else {
                NotificationCenter.default.post(name: Self.runnableDeletedNotification, object: manager, userInfo: [Self.runnableKey: runnable])
            }
        }
    }
}

/// The bundle that holds `LaunchPadLayout.plist` and the folder title strings: this app's, as the
/// original uses Dock's. Tests point it at the sources' resource directory.
nonisolated(unsafe) var launchPadBundle = Bundle.main

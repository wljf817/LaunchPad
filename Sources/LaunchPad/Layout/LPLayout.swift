import Foundation

/// Places apps into the pages of a root: the initial layout of a new database, new apps at the
/// next available space, and the corrections made at startup (REF-LAYOUT-005, REF-LAYOUT-007).
///
/// Thread confinement: used on the main thread only.
@objc(LPLayout)
final class LPLayout: NSObject, @unchecked Sendable {
    /// While false, the page and item added blocks are not called.
    var callAddedBlocks = false
    var pageAdded: (@convention(block) (LPPage, UInt) -> Void)?
    var itemAdded: (@convention(block) (LPItem, UInt) -> Void)?
    var itemNotAdded: (@convention(block) (LPItem) -> Void)?
    var templateDictionary: NSDictionary?
    var excludeList: LPLayoutExcludeList
    var includeAsGameList: LPLayoutIncludeAsGameList
    @objc let rootPage: LPRoot
    /// Source path → the smallest depth of an app under it in `currentTree`.
    var rootPathsToDepth: [String: UInt] = [:]
    var rootPaths: [String] = []
    @objc let maxPerPage: UInt
    @objc let maxPerGroupPage: UInt
    var currentTree: LPAppTree
    var _itemMoved: (@convention(block) (LPItem, UInt) -> Void)?
    var _itemRemoved: (@convention(block) (LPItem) -> Void)?

    /// `LaunchPadLayout.plist` (REF-LAYOUT-004), read once per process; the original reads it in
    /// `+initialize`.
    nonisolated(unsafe) static let layoutDictionary: NSDictionary? = launchPadBundle.path(forResource: "LaunchPadLayout", ofType: "plist")
        .flatMap { NSDictionary(contentsOfFile: $0) }

    @objc var layoutKey: String { "launchpad" }

    /// `sources` are the source paths in source order (REF-LAYOUT-003); the Utilities folder of
    /// `/Applications` and of `/System/Applications` follows each of them.
    @objc(initWithRootPage:sources:maxItemsPerPage:maxItemsPerGroup:)
    init(rootPage: LPRoot, sources: [Any], maxItemsPerPage: UInt, maxItemsPerGroup: UInt) {
        self.rootPage = rootPage
        maxPerPage = maxItemsPerPage
        maxPerGroupPage = maxItemsPerGroup
        excludeList = LPLayoutExcludeList(dictionary: nil)
        includeAsGameList = LPLayoutIncludeAsGameList(dictionary: nil)
        currentTree = LPAppTree()
        super.init()
        templateDictionary = Self.layoutDictionary?[layoutKey] as? NSDictionary
        excludeList = LPLayoutExcludeList(dictionary: templateDictionary?["exclude"] as? NSDictionary)
        includeAsGameList = LPLayoutIncludeAsGameList(dictionary: templateDictionary?["includeAsGame"] as? NSDictionary)
        for case let path as String in sources {
            rootPaths.append(path)
            rootPathsToDepth[path] = 10000
            if path == "/Applications" {
                rootPaths.append("/Applications/Utilities")
                rootPathsToDepth["/Applications/Utilities"] = 10000
            }
            if path == "/System/Applications" {
                rootPaths.append("/System/Applications/Utilities")
                rootPathsToDepth["/System/Applications/Utilities"] = 10000
            }
        }
        rootPage.iterateChildren { [self] item, _ in
            if let app = item as? LPApp {
                _addApp(app, toTree: currentTree)
            }
        }
    }

    @objc var pageAddedBlock: (@convention(block) (LPPage, UInt) -> Void)? {
        get { pageAdded }
        set { pageAdded = newValue }
    }

    @objc var itemAddedBlock: (@convention(block) (LPItem, UInt) -> Void)? {
        get { itemAdded }
        set { itemAdded = newValue }
    }

    @objc var itemNotAddedBlock: (@convention(block) (LPItem) -> Void)? {
        get { itemNotAdded }
        set { itemNotAdded = newValue }
    }

    @objc var itemMoved: (@convention(block) (LPItem, UInt) -> Void)? {
        get { _itemMoved }
        set { _itemMoved = newValue }
    }

    @objc var itemRemoved: (@convention(block) (LPItem) -> Void)? {
        get { _itemRemoved }
        set { _itemRemoved = newValue }
    }

    @objc var excludeListVersion: UInt { excludeList.version }
    @objc var includeAsGameListVerison: UInt { includeAsGameList.version }
    @objc var curationVerison: UInt {
        UInt(bitPattern: (((templateDictionary?["layout"] as? NSDictionary)?["version"]) as AnyObject?)?.integerValue ?? 0)
    }

    /// Items sorted by title: case-insensitive, localized, numeric.
    @objc class var sortDescriptors: [NSSortDescriptor] { titleSortDescriptors }
    nonisolated(unsafe) private static let titleSortDescriptors = [
        NSSortDescriptor(key: "title", ascending: true) { a, b in
            let a = a as! NSString
            let b = b as! NSString
            let result = CFStringCompareWithOptions(a, b, CFRange(location: 0, length: a.length), [.compareCaseInsensitive, .compareLocalized, .compareNumerically])
            return ComparisonResult(rawValue: result.rawValue) ?? .orderedSame
        },
    ]

    private static func sorted(_ items: NSArray) -> [LPItem] {
        items.sortedArray(using: sortDescriptors) as! [LPItem]
    }

    /// A string of this app's bundle in the user's language (REF-LAYOUT-009).
    private static func localized(_ key: String) -> String {
        launchPadBundle.localizedString(forKey: key, value: "", table: nil)
    }

    // MARK: Trees

    /// Adds the app to `tree` and records its depth under the first source path above it (an app
    /// in a Utilities folder counts for the Utilities path, not for its parent).
    @objc(_addApp:toTree:)
    func _addApp(_ app: LPItem & LPLayoutItem, toTree tree: LPAppTree) {
        let node = tree.addApp(app)
        let parentPath = node.parent?.path ?? ""
        let depth = node.depth
        for root in rootPaths {
            guard parentPath.hasPrefix(root) else { continue }
            if root == "/Applications", parentPath.hasPrefix("/Applications/Utilities") { continue }
            if root == "/System/Applications", parentPath.hasPrefix("/System/Applications/Utilities") { continue }
            if depth < rootPathsToDepth[root] ?? 0 {
                rootPathsToDepth[root] = depth
            }
            return
        }
    }

    @objc(_addApps:toTree:)
    func _addApps(_ items: [LPItem], toTree tree: LPAppTree) {
        for item in items {
            if let group = item as? LPGroup {
                _addApps(group.children as! [LPItem], toTree: tree)
            } else if let app = item as? LPItem & LPLayoutItem {
                _addApp(app, toTree: tree)
            }
        }
    }

    /// The items the exclude list does not exclude; each excluded one goes to the not-added block.
    @objc(_itemsFilteringIgnoredItems:)
    func _itemsFilteringIgnoredItems(_ items: [LPItem]) -> [LPItem] {
        var kept: [LPItem] = []
        var ignored: [LPItem] = []
        for item in items {
            if let layoutItem = item as? LPLayoutItem, excludeList.itemExcluded(layoutItem) {
                ignored.append(item)
            } else {
                kept.append(item)
            }
        }
        if let itemNotAdded {
            for item in ignored {
                itemNotAdded(item)
            }
        }
        return kept
    }

    // MARK: Initial layout

    /// The first layout of a new database from all apps found (REF-LAYOUT-005).
    @objc(layoutForInitial:)
    @discardableResult
    func layoutForInitial(_ items: [LPItem]) -> Bool {
        let tree = LPAppTree()
        callAddedBlocks = false
        let kept = _itemsFilteringIgnoredItems(items)
        _addApps(kept, toTree: currentTree)
        tree.addApps(kept)
        _addAllFirstPageApplications(tree)
        _addBetaApplications(tree, withOptions: 0x20)
        _addGameApplications(tree, withOptions: 0x20)
        _addAppleApplications(tree, withOptions: 0x20)
        _layoutTree(tree, withOptions: 2)
        callAddedBlocks = true
        return true
    }

    /// The first page from `mainPage` (REF-LAYOUT-004), then resizing; and, as the original does,
    /// three empty folders titled `Other` in the hidden page.
    @objc(_addAllFirstPageApplications:)
    func _addAllFirstPageApplications(_ tree: LPAppTree) {
        let entries = (templateDictionary?["layout"] as? NSDictionary)?["mainPage"] as? [NSDictionary] ?? []
        let pages = rootPage.children
        var firstPage = pages.count != 0 ? pages[0] as? LPItem & LPItemContainer : nil
        if firstPage == nil {
            let page = LPPage(items: nil)
            pages.add(page)
            firstPage = page
        }
        _processEntries(entries, intoParent: firstPage!, withAppTree: tree)
        fixupItemsPerPageAndGroup()
        for _ in 0..<3 {
            rootPage.purgatory.children.add(LPGroup(groupWithTitle: "Other", andChildren: nil))
        }
    }

    /// `bundleid` entries move every app with that ID out of `tree` into the parent (a folder's
    /// first page with room); `group` entries become auto-generated folders with one page.
    @objc(_processEntries:intoParent:withAppTree:)
    func _processEntries(_ entries: [NSDictionary], intoParent parent: LPItem & LPItemContainer, withAppTree tree: LPAppTree) {
        for entry in entries {
            if !isEqualToString(entry["type"] as? String, "group") {
                let pagesOnly = parent.pagesOnly
                let siblings = parent.children
                let nodes = (tree.nodes(forBundleIdentifier: entry["bundleid"] as? String)?.copy() as? NSSet) ?? []
                for case let node as LPAppTreeApp in nodes {
                    let app = node.app
                    if pagesOnly {
                        (parent as? LPGroup)?.firstAvailablePage(withMaxCount: maxPerGroupPage, createIfNecessary: true)?.children.add(app)
                    } else {
                        siblings.add(app)
                    }
                    tree.removeApp(app)
                }
            } else {
                let title = entry["title"] as? String
                let contents = entry["contents"] as? [NSDictionary] ?? []
                guard let title, !title.isEmpty, parent is LPPage else {
                    NSLog("************* LaunchPadLayout.plist corrupt. Please file a bug. *************")
                    continue
                }
                guard !contents.isEmpty else { continue }
                let group = LPGroup(groupWithTitle: Self.localized(title), andChildren: nil)
                let page = LPPage(items: nil)
                parent.children.add(group)
                group.children.add(page)
                _processEntries(contents, intoParent: group, withAppTree: tree)
                group.autoGenerated = true
            }
        }
    }

    /// Collects the apps of `tree` that `include` accepts into a promise of `kind`, sorted by title,
    /// taking them out of the tree; nil when there are none.
    private func promise(_ title: String, kind: UInt, from tree: LPAppTree, atPath path: String = "/",
                         including include: (LPItem & LPLayoutItem) -> Bool) -> _LPGroupPromise? {
        let found = NSMutableArray()
        tree.iterateAllApps(atPath: path) { node, _ in
            if let app = node.app as? LPItem & LPLayoutItem, include(app) {
                found.add(app)
            }
        }
        var promise: _LPGroupPromise?
        if found.count != 0 {
            let made = _LPGroupPromise(title: title, kind: kind)
            for case let app as LPItem & LPLayoutItem in found {
                made.children.add(app)
                tree.removeApp(app)
            }
            promise = made
        }
        promise?.children.sort(using: Self.sortDescriptors)
        return promise
    }

    /// TestFlight apps (kind 2). Without a TestFlight folder yet, beta apps already in folders are
    /// put first: the original compares their folder with nil (research paper §16).
    @objc(_addBetaApplications:withOptions:)
    func _addBetaApplications(_ tree: LPAppTree, withOptions options: UInt) {
        let promise = promise(Self.localized("TestFlight"), kind: 2, from: tree) { app in
            guard let runnable = app as? LPRunnable else { return false }
            return !runnable.notFound && runnable.isBeta
        }
        guard let promise else { return }
        if groupForKind(2) == nil {
            rootPage.iterateChildren { item, _ in
                if let runnable = item as? LPRunnable, !runnable.notFound, runnable.isBeta, runnable.parentGroup != nil {
                    promise.children.insert(runnable, at: 0)
                }
            }
        }
        _layoutItemsToNextAvailableSpace([promise], withOptions: options)
    }

    /// Games (kind 1): by category or the include-as-game list.
    @objc(_addGameApplications:withOptions:)
    func _addGameApplications(_ tree: LPAppTree, withOptions options: UInt) {
        let isGame: (LPItem & LPLayoutItem) -> Bool = { [self] app in
            guard let runnable = app as? LPRunnable, !runnable.notFound else { return false }
            return runnable.isGame() || includeAsGameList.itemIncluded(runnable)
        }
        let promise = promise(Self.localized("Games"), kind: 1, from: tree, including: isGame)
        guard let promise else { return }
        if groupForKind(1) == nil {
            rootPage.iterateChildren { item, _ in
                if let runnable = item as? LPRunnable, isGame(runnable), runnable.parentGroup != nil {
                    promise.children.insert(runnable, at: 0)
                }
            }
        }
        _layoutItemsToNextAvailableSpace([promise], withOptions: options)
    }

    /// Apple's apps in `/Applications/Server`, and everything in `/AppleInternal`.
    @objc(_addAppleApplications:withOptions:)
    func _addAppleApplications(_ tree: LPAppTree, withOptions options: UInt) {
        var promises: [_LPGroupPromise] = []
        let server = promise(Self.localized("Server"), kind: 0, from: tree, atPath: "/Applications/Server") { app in
            app.bundleIdentifier?.lowercased().hasPrefix("com.apple.") ?? false
        }
        if let server {
            promises.append(server)
        }
        if let appleInternal = promise("AppleInternal", kind: 0, from: tree, atPath: "/AppleInternal", including: { _ in true }) {
            promises.append(appleInternal)
        }
        if !promises.isEmpty {
            _layoutItemsToNextAvailableSpace(promises, withOptions: options)
        }
    }

    /// Each source path in turn, then whatever is left, sorted by title.
    @objc(_layoutTree:withOptions:)
    func _layoutTree(_ tree: LPAppTree, withOptions options: UInt) {
        for path in rootPaths {
            _processTree(tree, forPath: path, withOptions: options)
        }
        let rest = NSMutableArray()
        tree.iterateAllApps(atPath: "/") { node, _ in
            rest.add(node.app)
        }
        rest.sort(using: Self.sortDescriptors)
        if rest.count != 0 {
            _layoutItemsToNextAvailableSpace(rest as! [LPItem], withOptions: options)
        }
    }

    /// Takes each directory or app directly under `path` out of the tree into a tree of its own,
    /// places it, and puts what was not placed back.
    @objc(_processTree:forPath:withOptions:)
    func _processTree(_ tree: LPAppTree, forPath path: String, withOptions options: UInt) {
        let node = tree.subNode(atPath: path)
        let leftOver = NSMutableArray()
        for case let child as LPAppTreeNode in (node?.children?.copy() as? NSArray) ?? [] {
            guard let childPath = child.path, let subtree = tree.splitOutTree(atPath: childPath) else { continue }
            _addSubTree(subtree, forPath: path, withOptions: options)
            subtree.iterateAllApps(atPath: "/") { node, _ in
                leftOver.add(node.app)
            }
        }
        tree.addApps(leftOver as! [LPItem])
    }

    /// REF-LAYOUT-005 step 7 for one directory under a source path: apps at the shallowest depth
    /// are placed one by one (in a Utilities path, each into an `Other` folder); deeper apps are
    /// grouped by the directory at that depth into its own apps and a `%@ (Other)` folder.
    @objc(_addSubTree:forPath:withOptions:)
    func _addSubTree(_ subtree: LPAppTree, forPath path: String, withOptions options: UInt) {
        let isTopLevel: Bool
        if path.hasPrefix("/Applications"), !path.hasPrefix("/Applications/Utilities") {
            isTopLevel = true
        } else if path.hasPrefix("/System/Applications") {
            isTopLevel = !path.hasPrefix("/System/Applications/Utilities")
        } else {
            isTopLevel = false
        }
        let limit = (rootPathsToDepth[path] ?? 0) + 1
        var nodes: [LPAppTreeApp] = []
        subtree.iterateAllApps(atPath: "/") { node, _ in
            let nodePath = node.path ?? ""
            if (nodePath.hasPrefix("/Applications/Utilities") || nodePath.hasPrefix("/System/Applications/Utilities")), isTopLevel {
                return
            }
            nodes.append(node)
        }
        let inSubdirectories = NSMutableDictionary()
        let direct = NSMutableDictionary()
        for node in nodes {
            let depth = node.depth
            if depth < limit {
                if !path.hasPrefix("/Applications/Utilities"), !path.hasPrefix("/System/Applications/Utilities") {
                    _layoutItemsToNextAvailableSpace([node.app], withOptions: options | 1)
                } else {
                    let promise = _LPGroupPromise(title: Self.localized("Other"), kind: 0)
                    promise.children.add(node.app)
                    _layoutItemsToNextAvailableSpace([promise], withOptions: options | 1)
                }
                subtree.removeApp(node.app)
            } else {
                var ancestor: LPAppTreeNode = node
                repeat {
                    ancestor = ancestor.parent!
                } while limit <= ancestor.depth
                let key = ancestor.localizedName ?? ""
                let app = node.app as! LPItem & LPLayoutItem
                if depth == limit {
                    var list = direct[key] as? NSMutableArray
                    if list == nil {
                        list = NSMutableArray()
                        direct[key] = list
                    }
                    list?.add(app)
                } else if let lpApp = app as? LPApp, lpApp.uiElement() {
                    itemNotAdded?(app)
                } else {
                    var list = inSubdirectories[key] as? NSMutableArray
                    if list == nil {
                        list = NSMutableArray()
                        inSubdirectories[key] = list
                    }
                    list?.add(app)
                }
                subtree.removeApp(app)
            }
        }
        let keys = NSMutableSet()
        keys.addObjects(from: inSubdirectories.allKeys)
        keys.addObjects(from: direct.allKeys)
        for case let key as String in (keys.allObjects as NSArray).sortedArray(using: #selector(NSString.compare(_:))) {
            var items: [Any] = []
            if let list = direct[key] as? NSArray, list.count != 0 {
                items += Self.sorted(list)
            }
            let promise = _LPGroupPromise(title: String(format: Self.localized("%@ (Other)"), key), kind: 0)
            if let list = inSubdirectories[key] as? NSArray, list.count != 0 {
                promise.children.addObjects(from: Self.sorted(list))
                items.append(promise)
            }
            _layoutItemsToNextAvailableSpace(items, withOptions: options | 1)
        }
    }

    /// The original's `_moveUtilitiesToOthersFolder` does nothing and is not reproduced.

    // MARK: Placing

    /// Places items one after another (REF-LAYOUT-005 step 8). Options: 1 keep together on one page
    /// when they fit, 2 start on the second page. Promises merge into folders of the same title or
    /// become new auto-generated folders.
    @objc(_layoutItemsToNextAvailableSpace:withOptions:)
    @discardableResult
    func _layoutItemsToNextAvailableSpace(_ items: [Any], withOptions options: UInt) -> Bool {
        let together = options & 1 != 0 && UInt(items.count) < maxPerPage
        let pages = rootPage.children
        var index = 0
        var page: LPPage?
        if options & 2 == 0, pages.count != 0 {
            index = 0
            page = pages[0] as? LPPage
        } else if options & 2 != 0, pages.count >= 2 {
            index = 1
            page = pages[1] as? LPPage
        }
        if page != nil, together {
            while let current = page {
                if UInt(current.children.count + items.count) <= maxPerPage {
                    break
                }
                index += 1
                if index >= pages.count {
                    page = nil
                    break
                }
                page = pages[index] as? LPPage
            }
        }

        for item in items {
            if let promise = item as? _LPGroupPromise {
                var merged = false
                for case let rootPageItem as LPPage in pages {
                    for case let group as LPGroup in rootPageItem.children where group.isGroup && isEqualToString(group.title, promise.title) {
                        group.kind = promise.kind
                        for case let child as LPItem in promise.children {
                            var target = group.firstAvailablePage(withMaxCount: maxPerGroupPage, createIfNecessary: false)
                            if target == nil {
                                let newPage = LPPage(items: nil)
                                group.children.add(newPage)
                                if callAddedBlocks {
                                    pageAdded?(newPage, UInt(group.children.count))
                                }
                                target = newPage
                            }
                            target!.children.add(child)
                            if callAddedBlocks {
                                itemAdded?(child, UInt(target!.children.count))
                            }
                        }
                        merged = true
                    }
                }
                if merged {
                    continue
                }
            }
            while true {
                if let current = page, UInt(current.children.count) < maxPerPage {
                    break
                }
                if index + 1 < pages.count {
                    page = pages[index + 1] as? LPPage
                } else {
                    let newPage = LPPage(items: nil)
                    pages.add(newPage)
                    if callAddedBlocks {
                        pageAdded?(newPage, UInt(pages.count - 1))
                    }
                    page = newPage
                }
                index += 1
            }
            guard let page else { continue }
            let placed: LPItem
            if let promise = item as? _LPGroupPromise {
                let group = LPGroup(groupWithTitle: promise.title, andChildren: nil)
                group.autoGenerated = true
                group.kind = promise.kind
                page.children.add(group)
                for case let child as LPItem in promise.children {
                    group.firstAvailablePage(withMaxCount: maxPerGroupPage, createIfNecessary: true)?.children.add(child)
                }
                placed = group
            } else {
                guard let plain = item as? LPItem else { continue }
                page.children.add(plain)
                placed = plain
            }
            if callAddedBlocks {
                itemAdded?(placed, UInt(page.children.count - 1))
            }
        }
        return true
    }

    /// Places items found after the first layout (REF-LAYOUT-007). Options: 8 no added blocks,
    /// 0x10 do not filter with the exclude list, otherwise as `_layoutItemsToNextAvailableSpace`.
    @objc(layoutItemsToNextAvailableSpace:withOptions:)
    @discardableResult
    func layoutItemsToNextAvailableSpace(_ items: [LPItem], withOptions options: UInt) -> Bool {
        let tree = LPAppTree()
        callAddedBlocks = options & 8 == 0
        let kept = options & 0x10 == 0 ? _itemsFilteringIgnoredItems(items) : items
        _addApps(kept, toTree: currentTree)
        tree.addApps(kept)
        _addBetaApplications(tree, withOptions: 0x20)
        _addGameApplications(tree, withOptions: 0x20)
        _addAppleApplications(tree, withOptions: 0x20)
        _layoutTree(tree, withOptions: options)
        let groups = kept.filter(\.isGroup)
        if !groups.isEmpty {
            _layoutItemsToNextAvailableSpace(groups, withOptions: 0)
        }
        callAddedBlocks = true
        return true
    }

    /// The first folder of `kind` anywhere under the root.
    @objc(groupForKind:)
    func groupForKind(_ kind: UInt) -> LPGroup? {
        var found: LPGroup?
        rootPage.iterateChildren { item, stop in
            if let group = item as? LPGroup, group.kind == kind {
                found = group
                stop.pointee = true
            }
        }
        return found
    }

    // MARK: Resizing

    /// REF-LAYOUT-005 step 9: folder pages split at the folder limit, auto-generated folders of the
    /// same title merged into the first, root pages split, empty root pages removed while more
    /// than one remains.
    @objc func fixupItemsPerPageAndGroup() {
        let byTitle = NSMutableDictionary()
        for case let page as LPPage in (rootPage.children.copy() as! NSArray) {
            for case let item as LPItem in (page.children.copy() as! NSArray) where item.isGroup {
                guard let group = item as? LPGroup else { continue }
                _ensureSizeOfPages(onRoot: group, maxPerPage: maxPerGroupPage)
                if group.autoGenerated {
                    let key = group.title as Any
                    var list = byTitle[key] as? NSMutableArray
                    if list == nil {
                        list = NSMutableArray()
                        byTitle[key] = list
                    }
                    list?.add(group)
                }
            }
        }
        for case let list as NSMutableArray in byTitle.allValues where list.count > 1 {
            let first = list.firstObject as! LPGroup
            list.removeObject(at: 0)
            for case let other as LPGroup in list {
                for case let otherPage as LPPage in (other.children.copy() as! NSArray) {
                    for case let child as LPItem in (otherPage.children.copy() as! NSArray) {
                        var target = first.firstAvailablePage(withMaxCount: maxPerGroupPage, createIfNecessary: false)
                        if target == nil {
                            let newPage = LPPage(items: nil)
                            first.children.add(newPage)
                            pageAdded?(newPage, UInt(first.children.count - 1))
                            target = newPage
                        }
                        target!.children.add(child)
                        _itemMoved?(child, UInt(target!.children.count - 1))
                    }
                }
                for case let otherPage as LPItem in (other.children.copy() as! NSArray) {
                    other.children.removeObject(identicalTo: otherPage)
                }
                other.parentContainer?.children.removeObject(identicalTo: other)
                _itemRemoved?(other)
            }
        }
        _ensureSizeOfPages(onRoot: rootPage, maxPerPage: maxPerPage)
        let pages = rootPage.children
        for case let page as LPPage in (pages.copy() as! NSArray) {
            if pages.count < 2 {
                break
            }
            if page.children.count == 0 {
                pages.remove(page)
                _itemRemoved?(page)
            }
        }
    }

    /// Moves what does not fit on each page of `container` to a new page right after it.
    @objc(_ensureSizeOfPagesOnRoot:maxPerPage:)
    func _ensureSizeOfPages(onRoot container: LPGroup, maxPerPage max: UInt) {
        for case var page as LPPage in (container.children.copy() as! NSArray) {
            var count = UInt(page.children.count)
            while max < count {
                let newPage = LPPage(items: nil)
                let index = container.children.indexOfObjectIdentical(to: page)
                let overflow = page.children.objects(at: IndexSet(integersIn: Int(max)..<Int(count)))
                container.children.insert(newPage, at: index + 1)
                pageAdded?(newPage, UInt(index + 1))
                for (position, item) in overflow.enumerated() {
                    newPage.children.add(item)
                    if let item = item as? LPItem {
                        _itemMoved?(item, UInt(position))
                    }
                }
                count = UInt(newPage.children.count)
                page = newPage
            }
        }
    }

    // MARK: Startup correction

    /// REF-LAYOUT-007: applies the exclude list and the include-as-game list when their stored
    /// versions are older than the layout data's, curates the first page when the stored curation
    /// version is 1, reports what ran, and resizes.
    @objc(fixupLayoutWithExcludeListVersion:includeAsGameListVersion:curationVersion:itemExcluded:itemIncludedAsGame:changesMade:)
    func fixupLayout(withExcludeListVersion excludeVersion: UInt, includeAsGameListVersion gameVersion: UInt, curationVersion: UInt,
                     itemExcluded: @escaping @convention(block) (LPItem) -> Void,
                     itemIncludedAsGame: @escaping @convention(block) (LPItem) -> Void,
                     changesMade: @convention(block) (Bool, Bool, Bool) -> Void) {
        let excludeChanged = excludeVersion < excludeListVersion
        if excludeChanged {
            _applyExcludeList(itemExcluded)
        }
        let gameChanged = gameVersion < includeAsGameListVerison
        if gameChanged {
            _applyIncludeAsGameList(itemIncludedAsGame)
        }
        if curationVersion == 1 {
            _curateAppleApps(1)
        }
        changesMade(excludeChanged, gameChanged, curationVersion == 1)
        fixupItemsPerPageAndGroup()
    }

    /// Hands every excluded item under the root to `block` (which removes it), then removes the
    /// folders and root pages that were left empty.
    @objc(_applyExcludeList:)
    func _applyExcludeList(_ block: (LPItem) -> Void) {
        let excluded = NSMutableSet()
        let emptyGroups = NSMutableSet()
        let emptyPages = NSMutableSet()
        rootPage.iterateChildren { [self] item, _ in
            if let layoutItem = item as? LPLayoutItem, excludeList.itemExcluded(layoutItem) {
                excluded.add(item)
            }
        }
        for case let item as LPItem in excluded {
            let parent = item.parentContainer
            block(item)
            if let parent, parent.isEmpty {
                if parent is LPPage {
                    emptyPages.add(parent)
                } else {
                    emptyGroups.add(parent)
                }
            }
        }
        for case let group as LPItem in emptyGroups {
            guard let page = group.parentPage else { continue }
            page.children.remove(group)
            if page.children.count == 0 {
                emptyPages.add(page)
            }
        }
        for page in emptyPages where rootPage.children.count > 1 {
            rootPage.children.remove(page)
        }
    }

    @objc(_applyIncludeAsGameList:)
    func _applyIncludeAsGameList(_ block: (LPItem) -> Void) {
        let games = NSMutableSet()
        rootPage.iterateChildren { [self] item, _ in
            if let layoutItem = item as? LPLayoutItem, includeAsGameList.itemIncluded(layoutItem) {
                games.add(item)
            }
        }
        for case let item as LPItem in games {
            block(item)
        }
    }

    // MARK: Curation

    /// Takes the apps of `mainPage` back off the pages (from folders only when the folder is the
    /// entry's group) into the hidden page, and inserts them again where `mainPage` puts them.
    @objc(_curateAppleApps:)
    func _curateAppleApps(_ version: UInt) {
        let pages = rootPage.children
        guard pages.count != 0, pages[0] is LPItem else { return }
        let purgatory = rootPage.purgatory
        let tree = LPAppTree()
        let entries = (templateDictionary?["layout"] as? NSDictionary)?["mainPage"] as? [NSDictionary] ?? []
        let titleSets = NSMutableDictionary()
        let hidden = purgatory.children
        let takeBack: (String, NSSet?) -> Void = { [self] bundleID, titles in
            for case let node as LPAppTreeApp in currentTree.nodes(forBundleIdentifier: bundleID) ?? [] {
                guard let app = node.app as? LPItem & LPLayoutItem else { continue }
                let parent = app.parentContainer
                let group = app.parentGroup
                let groupTitle = group?.title
                guard parent !== purgatory else { continue }
                if parent == nil || pages.indexOfObjectIdentical(to: parent!) == NSNotFound {
                    guard let groupTitle, titles?.contains(groupTitle) == true else { continue }
                }
                hidden.add(app)
                tree.addApp(app)
                if let group, group.isEmpty {
                    group.parentPage?.children.remove(group)
                }
            }
        }
        _iterateCurateEntries(entries) { entry, isGroup in
            if let bundleID = entry["bundleid"] as? String {
                takeBack(bundleID, nil)
            }
            if isGroup {
                let title = entry["title"] as? String
                let alias = entry["alias"] as? String ?? ""
                let titles = NSSet(array: [Self.localized(title ?? ""), Self.localized(alias), title as Any, alias])
                titleSets[title as Any] = titles
                let contents = entry["contents"] as? [NSDictionary] ?? []
                _iterateCurateEntries(contents) { entry, _ in
                    if let bundleID = entry["bundleid"] as? String {
                        takeBack(bundleID, titles)
                    }
                    return true
                }
            }
            return true
        }
        _insertFirstPageApplications(tree)
    }

    /// Visits entries depth first, a group before its contents; stops when `block` returns false.
    @objc(_iterateCurateEntries:entryBlock:)
    @discardableResult
    func _iterateCurateEntries(_ entries: [NSDictionary], entryBlock block: (NSDictionary, Bool) -> Bool) -> Bool {
        for entry in entries {
            let isGroup = isEqualToString(entry["type"] as? String, "group")
            if !block(entry, isGroup) {
                return false
            }
            if isGroup, !_iterateCurateEntries(entry["contents"] as? [NSDictionary] ?? [], entryBlock: block) {
                return false
            }
        }
        return true
    }

    @objc(_insertFirstPageApplications:)
    func _insertFirstPageApplications(_ tree: LPAppTree) {
        let entries = (templateDictionary?["layout"] as? NSDictionary)?["mainPage"] as? [NSDictionary] ?? []
        let pages = rootPage.children
        let firstPage = pages.count == 0 ? nil : pages[0] as? LPGroup
        _insertCuratedItems(entries, fromTree: tree, intoGroup: firstPage)
        fixupItemsPerPageAndGroup()
    }

    /// Inserts the apps of `tree` into `group` in `mainPage` order: next to the nearest entry already
    /// in the group, looking alternately after and before; folders are found by title or created.
    @objc(_insertCuratedItems:fromTree:intoGroup:)
    func _insertCuratedItems(_ entries: [NSDictionary], fromTree tree: LPAppTree, intoGroup group: LPGroup?) {
        guard let group else { return }
        let count = entries.count
        let byBundleID = NSMutableDictionary()
        let byTitle = NSMutableDictionary()
        group.iterateChildren { item, _ in
            if let layoutItem = item as? LPLayoutItem {
                let key = layoutItem.bundleIdentifier as Any
                if byBundleID[key] == nil {
                    byBundleID[key] = item
                }
            } else if item.isGroup {
                let key = item.title as Any
                if byTitle[key] == nil {
                    byTitle[key] = item
                }
            }
        }
        let lookUp: (NSDictionary) -> LPItem? = { entry in
            if !isEqualToString(entry["type"] as? String, "group") {
                guard let bundleID = entry["bundleid"] as? String else { return nil }
                return byBundleID[bundleID] as? LPItem
            }
            let title = entry["title"] as? String
            return (byTitle[Self.localized(title ?? "")] ?? byTitle[title as Any]) as? LPItem
        }
        /// Remembers an inserted app and takes it out of the tree.
        func record(_ item: LPItem) {
            if let app = item as? LPItem & LPLayoutItem {
                byBundleID[app.bundleIdentifier as Any] = item
                tree.removeApp(app)
            }
        }
        let insert: (LPItem, Int) -> Void = { [self] item, position in
            let children = group.children
            var index = 0
            if position != 0 {
                var after = position + 1
                var hasAfter = after < count
                var hasBefore = position - 1 >= 0
                var before = position - 2
                var placed = false
                var keepLooking = hasBefore || hasAfter
                while keepLooking {
                    if hasAfter {
                        if let neighbour = lookUp(entries[after]) {
                            let found = children.indexOfObjectIdentical(to: neighbour)
                            if found != NSNotFound {
                                index = found
                                placed = true
                                break
                            }
                        }
                        after += 1
                    }
                    if !hasBefore {
                        index = 0
                        placed = true
                        break
                    }
                    if let neighbour = lookUp(entries[before + 1]) {
                        let found = children.indexOfObjectIdentical(to: neighbour)
                        if found != NSNotFound {
                            index = found + 1
                            placed = true
                            break
                        }
                    }
                    hasBefore = before >= 0
                    hasAfter = after < count
                    keepLooking = before >= 0 || after < count
                    before -= 1
                }
                if !placed {
                    children.add(item)
                    index = children.count - 1
                    itemAdded?(item, UInt(index))
                    record(item)
                    return
                }
            }
            children.insert(item, at: index)
            itemAdded?(item, UInt(index))
            record(item)
        }
        for position in 0..<count {
            let entry = entries[position]
            if !isEqualToString(entry["type"] as? String, "group") {
                let nodes = (tree.nodes(forBundleIdentifier: entry["bundleid"] as? String)?.copy() as? NSSet) ?? []
                for case let node as LPAppTreeApp in nodes {
                    if let app = node.app as? LPItem {
                        insert(app, position)
                    }
                }
            } else {
                var folder = lookUp(entry) as? LPGroup
                if folder == nil {
                    let created = LPGroup(groupWithTitle: Self.localized(entry["title"] as? String ?? ""), andChildren: nil)
                    let page = LPPage(items: nil)
                    created.autoGenerated = true
                    insert(created, position)
                    byTitle[created.title as Any] = created
                    created.children.add(page)
                    folder = created
                }
                _insertCuratedItems(entry["contents"] as? [NSDictionary] ?? [], fromTree: tree, intoGroup: folder?.children.firstObject as? LPGroup)
            }
        }
    }
}

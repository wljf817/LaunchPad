import Foundation

/// The top of a tree. Its first stored child is the hidden page ("purgatory") that holds apps found
/// but not placed yet; `children` leaves it out, so index 0 of `children` is the first real page.
@objc(LPRoot)
class LPRoot: LPPage, @unchecked Sendable {
    @objc convenience init() {
        let purgatory = LPPage(items: nil)
        self.init(groupWithTitle: nil, andChildren: nil)
        super.children.insert(purgatory, at: 0)
    }

    @objc(initWithItems:)
    convenience init(items: [Any]?) {
        preconditionFailure("This method must not be called on a LPRoot class")
    }

    @objc override var isPage: Bool { false }
    @objc override var isRoot: Bool { true }
    @objc override var pagesOnly: Bool { true }
    @objc override var isEmpty: Bool { children.count == 0 }

    @objc override var children: NSMutableArray { mutableArrayValue(forKey: "rootChildren") }
    @objc override var storageChildren: NSArray { super.children }

    /// Only a change is passed on: the root's own flag is written directly, then every descendant gets
    /// the value, depth first (REF-GRID-015).
    @objc(setShouldCacheIcons:)
    override func setShouldCacheIcons(_ shouldCacheIcons: Bool) {
        guard _shouldCacheIcons != shouldCacheIcons else { return }
        _shouldCacheIcons = shouldCacheIcons
        iterateChildren { child, _ in
            child.setShouldCacheIcons(shouldCacheIcons)
        }
    }

    /// Sets the children read from the database, the hidden page included.
    @objc(setRawChildren:)
    func setRawChildren(_ children: [Any]) {
        super.children.setArray(children)
    }

    @objc func countOfRootChildren() -> UInt {
        let count = super.children.count
        return count == 0 ? 0 : UInt(count - 1)
    }

    @objc(objectInRootChildrenAtIndex:)
    func objectInRootChildren(at index: UInt) -> Any? {
        let children = super.children
        return Int(index) + 1 < children.count ? children[Int(index) + 1] : nil
    }

    @objc(insertObject:inRootChildrenAtIndex:)
    func insertObject(_ page: LPItem, inRootChildrenAt index: UInt) {
        super.children.insert(page, at: Int(index) + 1)
    }

    @objc(removeObjectFromRootChildrenAtIndex:)
    func removeObjectFromRootChildren(at index: UInt) {
        let children = super.children
        if Int(index) + 1 < children.count {
            children.removeObject(at: Int(index) + 1)
        }
    }

    // MARK: Purgatory

    @objc var purgatory: LPPage {
        let children = super.children
        if children.count == 0 {
            let page = LPPage(items: nil)
            children.insert(page, at: 0)
            return page
        }
        return children[0] as! LPPage
    }

    @objc var allPurgatoryItems: [LPItem] {
        purgatory.children.copy() as! [LPItem]
    }

    @objc(addItemToPurgatory:)
    func addItemToPurgatory(_ item: LPItem) {
        if item.parentPage !== purgatory {
            purgatory.children.add(item)
        }
    }

    @objc func purgePurgatory() {
        purgatory.children.removeAllObjects()
    }
}

// MARK: - LPStorage

extension LPRoot {
    @objc override var storageType: Int { 1 }
}

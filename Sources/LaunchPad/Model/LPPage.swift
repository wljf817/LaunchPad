import Foundation

/// A page of the grid, or of a folder. Pages hold apps and folders.
@objc(LPPage)
class LPPage: LPGroup, @unchecked Sendable {
    @objc(initWithItems:)
    convenience init(items: [Any]?) {
        self.init(groupWithTitle: nil, andChildren: items)
    }

    @objc override var isGroup: Bool { false }
    @objc override var isPage: Bool { true }
    @objc override var pagesOnly: Bool { false }
    @objc override var isEmpty: Bool { children.count == 0 }
}

// MARK: - LPStorage

extension LPPage {
    @objc override var storageType: Int { 3 }

    /// Pages have no title to save.
    @objc override func updateTitleStorage() {}
}

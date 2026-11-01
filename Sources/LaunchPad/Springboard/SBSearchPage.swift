import Foundation

/// A page of search results: the main grid's page item while searching (REF-SEARCH-009).
@objc(SBSearchPage)
final class SBSearchPage: NSObject {
    @objc let items: NSArray

    @objc(initWithItems:)
    init(items: NSArray) {
        self.items = items
        super.init()
    }
}

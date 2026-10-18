import Foundation

/// The apps the layout leaves out: bundle IDs and rules (REF-LAYOUT-004 `exclude`).
@objc(LPLayoutExcludeList)
final class LPLayoutExcludeList: NSObject, @unchecked Sendable {
    var bundleIDExcludeList: NSSet?
    @objc var version: UInt = 0
    var rulesBasedExcludeList: [_LPLayoutRule] = []

    @objc(initWithDictionary:)
    init(dictionary: NSDictionary?) {
        super.init()
        if let bundleIDs = dictionary?["bundleids"] as? [Any] {
            bundleIDExcludeList = NSSet(array: bundleIDs)
        }
        let rules = dictionary?["rules"] as? [NSDictionary] ?? []
        rulesBasedExcludeList = rules.compactMap { _LPLayoutRule.rule($0) }
        version = UInt(bitPattern: (dictionary?["version"] as AnyObject?)?.integerValue ?? 0)
    }

    /// Store apps and apps the user added are never excluded.
    @objc(itemExcluded:)
    func itemExcluded(_ item: LPLayoutItem) -> Bool {
        guard !item.isStoreApp, !item.addedByUser else { return false }
        if let bundleID = item.bundleIdentifier, bundleIDExcludeList?.contains(bundleID) == true {
            return true
        }
        return rulesBasedExcludeList.contains { $0.matchItem(item) }
    }
}

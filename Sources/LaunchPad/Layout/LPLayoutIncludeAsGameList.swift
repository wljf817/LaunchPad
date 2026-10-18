import Foundation

/// Apps the layout treats as games whatever their category (REF-LAYOUT-004 `includeAsGame`).
@objc(LPLayoutIncludeAsGameList)
final class LPLayoutIncludeAsGameList: NSObject, @unchecked Sendable {
    var bundleIDIncludeAsGameList: NSSet?
    @objc var version: UInt = 0

    @objc(initWithDictionary:)
    init(dictionary: NSDictionary?) {
        super.init()
        if let bundleIDs = dictionary?["bundleids"] as? [Any] {
            bundleIDIncludeAsGameList = NSSet(array: bundleIDs)
        }
        version = UInt(bitPattern: (dictionary?["version"] as AnyObject?)?.integerValue ?? 0)
    }

    @objc(itemIncluded:)
    func itemIncluded(_ item: LPLayoutItem) -> Bool {
        guard !item.isStoreApp, !item.addedByUser, let bundleID = item.bundleIdentifier else { return false }
        return bundleIDIncludeAsGameList?.contains(bundleID) == true
    }
}

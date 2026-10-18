import Foundation

/// One rule of the exclude list: a string matched against an app's file name or bundle ID.
@objc(_LPLayoutRule)
class _LPLayoutRule: NSObject, @unchecked Sendable {
    @objc let stringToMatch: String
    @objc let matchesToBundleIdentifier: Bool

    /// The rule for a dictionary with `type` `prefix`, `match` or `contains`; nil for other types.
    @objc(rule:)
    class func rule(_ dictionary: NSDictionary) -> _LPLayoutRule? {
        let ruleClass: _LPLayoutRule.Type
        switch dictionary["type"] as? String {
        case "prefix": ruleClass = _LPLayoutPrefixRule.self
        case "match": ruleClass = _LPLayoutMatchRule.self
        case "contains": ruleClass = _LPLayoutContainsRule.self
        default: return nil
        }
        return ruleClass.init(rule: dictionary)
    }

    /// Matches `name` when it has one, otherwise `bundleid`; nil without either.
    @objc(initWithRule:)
    required init?(rule: NSDictionary) {
        if let name = rule["name"] as? String, !name.isEmpty {
            stringToMatch = name
            matchesToBundleIdentifier = false
        } else if let bundleID = rule["bundleid"] as? String {
            stringToMatch = bundleID
            matchesToBundleIdentifier = true
        } else {
            return nil
        }
        super.init()
    }

    @objc(matchItem:)
    func matchItem(_ item: LPLayoutItem) -> Bool {
        match(matchesToBundleIdentifier ? item.bundleIdentifier : item.excludeListName)
    }

    @objc(match:)
    func match(_ string: String?) -> Bool { false }
}
